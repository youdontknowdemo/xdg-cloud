import Foundation
// icloud-uploaded — reports iCloud upload state per path. FAIL CLOSED.
//
// Used ONLY by cloud-xdg-provision.sh's `--icloud-evict` to prove a file's cloud copy is fully
// uploaded BEFORE evicting the local copy. The upload signal (NSURLUbiquitousItemIsUploadedKey)
// has no stock CLI surface, which is why this tiny compiled reader exists.
//
// argv:   one or more file paths.
// stdout: one line per path — "<state>\t<path>", state ∈ {uploaded, not-uploaded, not-in-icloud, error}.
// exit:   0  iff EVERY argv path is `uploaded` (safe to evict)
//         1  if any path is not-uploaded / not-in-icloud / unreadable  (fail closed → do NOT evict)
//         2  usage error
//
// FAIL CLOSED: any read failure, nil, or unknown resource value is treated as NOT uploaded.
let args = Array(CommandLine.arguments.dropFirst())
if args.isEmpty {
    FileHandle.standardError.write(Data("usage: icloud-uploaded <path>...\n".utf8))
    exit(2)
}

let keys: Set<URLResourceKey> = [
    .isUbiquitousItemKey,
    .ubiquitousItemIsUploadedKey,
    .ubiquitousItemIsUploadingKey,
    .ubiquitousItemDownloadingStatusKey,
]

var allSafe = true
for path in args {
    let url = URL(fileURLWithPath: path)
    var state = "error"
    do {
        let v = try url.resourceValues(forKeys: keys)
        if v.isUbiquitousItem != true {
            state = "not-in-icloud"; allSafe = false            // not an iCloud item → never evict
        } else if v.ubiquitousItemIsUploaded == true {          // Optional<Bool>; nil ⇒ falls to else
            state = "uploaded"                                  // the ONLY safe-to-evict state
        } else {
            state = "not-uploaded"; allSafe = false
        }
    } catch {
        state = "error"; allSafe = false                        // FAIL CLOSED on any read error
    }
    print("\(state)\t\(path)")
}
exit(allSafe ? 0 : 1)
