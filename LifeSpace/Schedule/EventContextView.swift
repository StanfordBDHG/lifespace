//
// This source file is part of LifeSpace based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2023 Stanford University
//
// SPDX-License-Identifier: MIT
//

import SpeziScheduler
import SwiftUI


struct EventContextView: View {
    let eventContext: EventContext
    
    
    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                HStack {
                    if eventContext.event.complete {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.accentColor)
                            .font(.system(size: 30))
                            .accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text(verbatim: eventContext.task.title)
                            .font(.headline)
                            .accessibilityLabel(
                                eventContext.event.complete
                                    ? "COMPLETED_TASK_LABEL \(eventContext.task.title)"
                                    : "TASK_LABEL \(eventContext.task.title)"
                            )
                        Text(verbatim: format(eventDate: eventContext.event.scheduledAt))
                            .font(.subheadline)
                    }
                }
                Divider()
                Text(eventContext.task.description)
                    .font(.callout)
                if !eventContext.event.complete {
                    Text(eventContext.task.context.actionType)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .foregroundColor(.white)
                        .background(Color.accentColor)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .padding(.top, 8)
                }
            }
        }
            .disabled(eventContext.event.complete)
            .contentShape(Rectangle())
    }
    
    
    private func format(eventDate: Date) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .none
        dateFormatter.timeStyle = .short
        return dateFormatter.string(from: eventDate)
    }
}


#if DEBUG
#Preview(traits: .sizeThatFitsLayout) {
    let task = LifeSpaceScheduler.dailySurveyTask
    
    return EventContextView(
        eventContext: EventContext(
            // We use a force unwrap in the preview as we can not recover from an error here
            // and the code will never end up in a production environment.
            // swiftlint:disable:next force_unwrapping
            event: task.events(from: .now.addingTimeInterval(-60 * 60 * 24)).first!,
            task: task
        )
    )
        .padding()
}
#endif
