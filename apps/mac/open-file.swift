// Reads a file as an app does: coordinated, allowed to download it if it is a
// placeholder (e2e.sh; the runner's shell may not download dataless files).
import Darwin
import Foundation

_ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS, IOPOL_MATERIALIZE_DATALESS_FILES_ON)
let url = URL(fileURLWithPath: CommandLine.arguments[1])
var coordError: NSError?
var readError: Error?
NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordError) { u in
    do { FileHandle.standardOutput.write(try Data(contentsOf: u)) } catch { readError = error }
}
if let e = coordError ?? readError as NSError? {
    FileHandle.standardError.write(Data("\(e)\n".utf8))
    exit(1)
}
