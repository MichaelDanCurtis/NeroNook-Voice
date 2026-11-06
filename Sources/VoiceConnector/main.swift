import Foundation

// Inert signed container executable. Nook attaches directly to the independently
// selected service and never launches this connector. No models/audio/accounts.
try? FileHandle.standardError.write(contentsOf: Data("Open Nero Voice separately, then connect this module in NeroNook.\n".utf8))
