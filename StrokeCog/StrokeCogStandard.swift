//
// This source file is part of the StrokeCog based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2023 Stanford University
//
// SPDX-License-Identifier: MIT
//

import CoreLocation
import FirebaseFirestore
import FirebaseStorage
import HealthKitOnFHIR
import OSLog
import PDFKit
import Spezi
import SpeziAccount
import SpeziFirebaseAccountStorage
import SpeziFirestore
import SpeziHealthKit
import SpeziOnboarding
import SpeziQuestionnaire
import SwiftUI


actor StrokeCogStandard: Standard, EnvironmentAccessible, HealthKitConstraint, OnboardingConstraint, AccountStorageConstraint {
    enum StrokeCogStandardError: Error {
        case userNotAuthenticatedYet
        case invalidStudyID
    }
    
    private static var userCollection: CollectionReference {
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "edu.stanford.lifespace"
        return Firestore.firestore().collection(bundleIdentifier).document("study").collection("ls_users")
    }
    
    @Dependency var accountStorage: FirestoreAccountStorage?
    
    @AccountReference var account: Account
    
    private let logger = Logger(subsystem: "StrokeCog", category: "Standard")
    
    
    private var userDocumentReference: DocumentReference {
        get async throws {
            guard let details = await account.details else {
                throw StrokeCogStandardError.userNotAuthenticatedYet
            }
            
            return Self.userCollection.document(details.accountId)
        }
    }
    
    private var userBucketReference: StorageReference {
        get async throws {
            guard let details = await account.details else {
                throw StrokeCogStandardError.userNotAuthenticatedYet
            }
            
            let bundleIdentifier = Bundle.main.bundleIdentifier ?? "edu.stanford.lifespace"
            return Storage.storage().reference().child("\(bundleIdentifier)/study/ls_users/\(details.accountId)")
        }
    }
    
    
    init() {
        if !FeatureFlags.disableFirebase {
            _accountStorage = Dependency(wrappedValue: FirestoreAccountStorage(storeIn: StrokeCogStandard.userCollection))
        }
    }
    
    
    func add(sample: HKSample) async {
        do {
            try await healthKitDocument(id: sample.id).setData(from: sample.resource)
        } catch {
            logger.error("Could not store HealthKit sample: \(error)")
        }
    }
    
    func remove(sample: HKDeletedObject) async {
        do {
            try await healthKitDocument(id: sample.uuid).delete()
        } catch {
            logger.error("Could not remove HealthKit sample: \(error)")
        }
    }
    
    func add(response: ModelsR4.QuestionnaireResponse) async {
        let id = response.identifier?.value?.value?.string ?? UUID().uuidString
        
        do {
            try await userDocumentReference
                .collection("QuestionnaireResponse") // Add all HealthKit sources in a /QuestionnaireResponse collection.
                .document(id) // Set the document identifier to the id of the response.
                .setData(from: response)
        } catch {
            logger.error("Could not store questionnaire response: \(error)")
        }
    }
    
    func add(location: CLLocationCoordinate2D) async throws {
        guard let details = await account.details else {
            throw StrokeCogStandardError.userNotAuthenticatedYet
        }
        
        guard let studyID = UserDefaults.standard.string(forKey: StorageKeys.studyID) else {
            throw StrokeCogStandardError.invalidStudyID
        }
        
        let dataPoint = LocationDataPoint(
            currentDate: Date(),
            time: Date().timeIntervalSince1970,
            latitude: location.latitude,
            longitude: location.longitude,
            studyID: studyID,
            updatedBy: details.accountId
        )
        
        try await userDocumentReference
            .collection("ls_location_data")
            .document(UUID().uuidString)
            .setData(from: dataPoint)
    }
    
    func fetchLocations(on date: Date = Date()) async throws -> [CLLocationCoordinate2D] {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        let endOfDay = Date(timeInterval: 24 * 60 * 60, since: startOfDay)
        
        var locations = [CLLocationCoordinate2D]()
        
        do {
            let snapshot = try await userDocumentReference
                .collection("ls_location_data")
                .whereField("currentDate", isGreaterThanOrEqualTo: startOfDay)
                .whereField("currentDate", isLessThan: endOfDay)
                .getDocuments()
            
            for document in snapshot.documents {
                if let longitude = document.data()["longitude"] as? CLLocationDegrees,
                   let latitude = document.data()["latitude"] as? CLLocationDegrees {
                    let coordinate = CLLocationCoordinate2D(
                        latitude: latitude,
                        longitude: longitude
                    )
                    locations.append(coordinate)
                }
            }
        } catch {
            self.logger.error("Error fetching location data: \(String(describing: error))")
            throw error
        }
        
        return locations
    }
    
    
    func add(response: DailySurveyResponse) async throws {
        guard let details = await account.details else {
            throw StrokeCogStandardError.userNotAuthenticatedYet
        }
        
        guard let studyID = UserDefaults.standard.string(forKey: StorageKeys.studyID) else {
            throw StrokeCogStandardError.invalidStudyID
        }
        
        var response = response
        
        response.timestamp = Date()
        response.studyID = studyID
        response.updatedBy = details.accountId
        
        try await userDocumentReference
            .collection("ls_surveys")
            .document(UUID().uuidString)
            .setData(from: response)
        
        // Update the user document with the latest survey date
        try await userDocumentReference.setData([
            "latestSurveyDate": response.surveyDate ?? ""
        ], merge: true)
    }
    
    func getLatestSurveyDate() async -> String {
        let document = try? await userDocumentReference.getDocument()
        
        if let data = document?.data(), let surveyDate = data["latestSurveyDate"] as? String {
            // Update the latest survey date in UserDefaults
            UserDefaults.standard.set(surveyDate, forKey: StorageKeys.lastSurveyDate)
            
            return surveyDate
        } else {
            return ""
        }
    }
    
    
    private func healthKitDocument(id uuid: UUID) async throws -> DocumentReference {
        try await userDocumentReference
            .collection("ls_healthkit") // Add all HealthKit sources in a /HealthKit collection.
            .document(uuid.uuidString) // Set the document identifier to the UUID of the document.
    }
    
    func deletedAccount() async throws {
        // delete all user associated data
        do {
            try await userDocumentReference.delete()
        } catch {
            logger.error("Could not delete user document: \(error)")
        }
    }
    
    /// Stores the given consent form in the user's document directory with a unique timestamped filename.
    ///
    /// - Parameter consent: The consent form's data to be stored as a `PDFDocument`.
    func store(consent: PDFDocument) async {
        let studyID = UserDefaults.standard.string(forKey: StorageKeys.studyID) ?? "unknownStudyID"
        
        guard !FeatureFlags.disableFirebase else {
            guard let basePath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
                logger.error("Could not create path for writing consent form to user document directory.")
                return
            }
            
            let filePath = basePath.appending(path: "consentForm_\(studyID)_consent.pdf")
            consent.write(to: filePath)
            
            return
        }
        
        do {
            guard let consentData = consent.dataRepresentation() else {
                logger.error("Could not store consent form.")
                return
            }
            
            let metadata = StorageMetadata()
            metadata.contentType = "application/pdf"
            _ = try await userBucketReference.child("consent/\(studyID)_consent.pdf").putDataAsync(consentData, metadata: metadata)
        } catch {
            logger.error("Could not store consent form: \(error)")
        }
    }
    
    /// Stores the given consent form in the user's document directory and in the consent bucket in Firebase
    ///
    /// - Parameter consentData: The consent form's data to be stored.
    /// - Parameter name: The name of the consent document.
    func store(consentData: Data, name: String) async {
        /// Adds the study ID to the file name
        let studyID = UserDefaults.standard.string(forKey: StorageKeys.studyID) ?? "unknownStudyID"
        let filename = "\(studyID)_\(name).pdf"
        
        guard let docURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            logger.error("Could not create path for writing consent form to user document directory.")
            return
        }
        
        let url = docURL.appendingPathComponent(filename)
        
        do {
            try consentData.write(to: url)
            
            let metadata = StorageMetadata()
            metadata.contentType = "application/pdf"
            _ = try await userBucketReference.child("ls_consent/\(filename)").putDataAsync(consentData, metadata: metadata)
        } catch {
            logger.error("Could not store consent form: \(error)")
        }
    }
    
    func isConsentFormUploaded(name: String) async -> Bool {
        do {
            let studyID = UserDefaults.standard.string(forKey: StorageKeys.studyID) ?? "unknownStudyID"
            _ = try await userBucketReference.child("ls_consent/\(studyID)_\(name).pdf").getMetadata()
            return true
        } catch {
            return false
        }
    }
    
    /// Update the user document with the user's study ID
    func setStudyID(_ studyID: String) async {
        do {
            try await userDocumentReference.setData([
                "studyID": studyID
            ], merge: true)
        } catch {
            logger.error("Unable to set Study ID: \(error)")
        }
    }
    
    func create(_ identifier: AdditionalRecordId, _ details: SignupDetails) async throws {
        guard let accountStorage else {
            preconditionFailure("Account Storage was requested although not enabled in current configuration.")
        }
        try await accountStorage.create(identifier, details)
    }
    
    func load(_ identifier: AdditionalRecordId, _ keys: [any AccountKey.Type]) async throws -> PartialAccountDetails {
        guard let accountStorage else {
            preconditionFailure("Account Storage was requested although not enabled in current configuration.")
        }
        return try await accountStorage.load(identifier, keys)
    }
    
    func modify(_ identifier: AdditionalRecordId, _ modifications: AccountModifications) async throws {
        guard let accountStorage else {
            preconditionFailure("Account Storage was requested although not enabled in current configuration.")
        }
        try await accountStorage.modify(identifier, modifications)
    }
    
    func clear(_ identifier: AdditionalRecordId) async {
        guard let accountStorage else {
            preconditionFailure("Account Storage was requested although not enabled in current configuration.")
        }
        await accountStorage.clear(identifier)
    }
    
    func delete(_ identifier: AdditionalRecordId) async throws {
        guard let accountStorage else {
            preconditionFailure("Account Storage was requested although not enabled in current configuration.")
        }
        try await accountStorage.delete(identifier)
    }
}
