import SwiftUI
import NookPluginSDK

struct InterruptionSensitivityView: View {
    @Binding var value: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text("Interruption sensitivity").font(.headline); Spacer(); Text("\(value)%").monospacedDigit().pluginSecondaryText() }
            Slider(value: Binding(get: { Double(value) }, set: { value = Int($0.rounded()) }), in: 0...100, step: 1)
                .accessibilityLabel("Interruption sensitivity")
            HStack { Text("Less sensitive"); Spacer(); Text("More sensitive") }.font(.caption).pluginSecondaryText()
            Text("Lower this if Nero or Ember interrupts itself. Lower values need firmer, longer speech. This only affects speaking over the assistant in Full duplex; it doesn’t change microphone volume.")
                .font(.caption).pluginSecondaryText().fixedSize(horizontal: false, vertical: true)
        }
    }
}
