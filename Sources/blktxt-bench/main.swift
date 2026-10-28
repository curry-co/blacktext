import BlktxtCore
import Foundation

// Generates a database that looks like years of heavy use, then times what BlackText does with it.
//
//   blktxt-bench seed    --db PATH [--years 10] [--words-per-day 10000]
//   blktxt-bench measure --db PATH

/// Small, fast, deterministic random numbers so every run builds the same database.
struct SplitMix64 {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func int(_ range: ClosedRange<Int>) -> Int {
        range.lowerBound + Int(next() % UInt64(range.count))
    }

    mutating func chance(_ p: Double) -> Bool {
        Double(next() % 1_000_000) / 1_000_000 < p
    }
}

let vocabulary = """
the of and to a in is it you that he was for on are with as I his they be at one have this from or had by \
word but what some we can out other were all there when up use your how said an each she which do their \
time if will way about many then them write would like so these her long make thing see him two has look \
more day could go come did number sound no most people my over know water than call first who may down side \
been now find any new work part take get place made live where after back little only round man year came \
show every good me give our under name very through just form sentence great think say help low line differ \
turn cause much mean before move right boy old too same tell does set three want air well also play small end \
put home read hand port large spell add even land here must big high such follow act why ask men change went \
light kind off need house picture try us again animal point mother world near build self earth father head \
stand own page should country found answer school grow study still learn plant cover food sun four between \
state keep eye never last let thought city tree cross farm hard start might story saw far sea draw left late \
run while press close night real life few north open seem together next white children begin got walk example \
ease paper group always music those both mark often letter until mile river car feet care second book carry \
took science eat room friend began idea fish mountain stop once base hear horse cut sure watch color face wood \
main enough plain girl usual young ready above ever red list though feel talk bird soon body dog family direct \
pose leave song measure door product black short numeral class wind question happen complete ship area half rock \
order fire south problem piece told knew pass since top whole king space heard best hour better true during \
hundred five remember step early hold west ground interest reach fast verb sing listen six table travel less \
morning ten simple several vowel toward war lay against pattern slow center love person money serve appear road \
map rain rule govern pull cold notice voice unit power town fine certain fly fall lead cry dark machine note wait \
plan figure star box noun field rest correct able pound done beauty drive stood contain front teach week final \
gave green oh quick develop ocean warm free minute strong special mind behind clear tail produce fact street inch \
multiply nothing course stay wheel full force blue object decide surface deep moon island foot system busy test \
record boat common gold possible plane stead dry wonder laugh thousand ago ran check game shape equate hot miss \
brought heat snow tire bring yes distant fill east paint language among coffee email meeting draft quote link
""".split(separator: " ").map(String.init)

func makeText(words: Int, rng: inout SplitMix64) -> String {
    var text = ""
    text.reserveCapacity(words * 6)
    var sentence = 0
    for index in 0..<words {
        var word = vocabulary[rng.int(0...(vocabulary.count - 1))]
        if sentence == 0 { word = word.prefix(1).uppercased() + word.dropFirst() }
        text += word
        sentence += 1
        if index == words - 1 {
            text += "."
        } else if sentence > rng.int(8...18) {
            text += rng.chance(0.15) ? ".\n\n" : ". "
            sentence = 0
        } else {
            text += " "
        }
    }
    return text
}

/// Most notes are short; some are long. Averages about 700 words.
func noteLength(rng: inout SplitMix64) -> Int {
    let roll = rng.int(0...99)
    if roll < 40 { return rng.int(3...60) }
    if roll < 80 { return rng.int(100...800) }
    return rng.int(1000...4000)
}

func argument(_ name: String, default value: String? = nil) -> String? {
    let args = CommandLine.arguments
    guard let index = args.firstIndex(of: name), index + 1 < args.count else { return value }
    return args[index + 1]
}

func seed() throws {
    guard let path = argument("--db") else { fatalError("--db PATH required") }
    let years = Double(argument("--years", default: "10")!)!
    let wordsPerDay = Int(argument("--words-per-day", default: "10000")!)!
    for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
    let store = try Store(url: URL(fileURLWithPath: path))
    var rng = SplitMix64(state: 42)
    let days = Int(years * 365)
    let start = Date().addingTimeInterval(-Double(days) * 86_400)
    let clock = Date()
    var notes = 0
    var versions = 0
    var words = 0
    var lastID: NoteID = 0

    for day in 0..<days {
        var written = 0
        while written < wordsPerDay {
            let length = noteLength(rng: &rng)
            var text = makeText(words: length, rng: &rng)
            if rng.chance(0.0001) { text += " zyzzyva" }
            let created = start.addingTimeInterval(Double(day) * 86_400 + Double(rng.int(25_000...80_000)))
            // A version every 100 words (capped at 20), dated as the note was written, plus the final text.
            let steps = min(length / 100, 20)
            var history: [(date: Date, text: String)] = []
            if steps > 0 {
                let parts = text.split(separator: " ", omittingEmptySubsequences: false)
                for step in 1...steps {
                    let prefix = parts.prefix(step * length / (steps + 1)).joined(separator: " ")
                    history.append((created.addingTimeInterval(Double(step) * 90), prefix))
                }
            }
            let updated = created.addingTimeInterval(Double(steps + 1) * 90)
            history.append((updated, text))
            lastID = try store.importNote(text: text, createdAt: created, updatedAt: updated, versions: history)
            notes += 1
            versions += history.count
            words += length
            written += length
        }
        if day % 365 == 364 {
            print(String(format: "  year %d: %d notes, %.1fM words, %.0fs", (day + 1) / 365, notes, Double(words) / 1e6, Date().timeIntervalSince(clock)))
        }
    }
    store.currentNoteID = lastID
    let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
    print(String(format: "Seeded %d notes, %d versions, %.1fM words in %.0fs. Database: %.0f MB",
                 notes, versions, Double(words) / 1e6, Date().timeIntervalSince(clock), Double(size) / 1e6))
}

/// Runs `body` several times and returns the median, in milliseconds.
func time(_ runs: Int = 7, _ body: () throws -> Void) rethrows -> Double {
    var samples: [Double] = []
    for _ in 0..<runs {
        let start = DispatchTime.now().uptimeNanoseconds
        try body()
        samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
    }
    return samples.sorted()[samples.count / 2]
}

var failures = 0

func report(_ name: String, _ ms: Double, target: Double?) {
    let verdict: String
    if let target {
        verdict = ms <= target ? "ok   (< \(Int(target)) ms)" : "SLOW (target \(Int(target)) ms)"
        if ms > target { failures += 1 }
    } else {
        verdict = ""
    }
    print("  " + name.padding(toLength: 44, withPad: " ", startingAt: 0) + String(format: "%9.2f ms  ", ms) + verdict)
}

func measure() throws {
    guard let path = argument("--db") else { fatalError("--db PATH required") }
    let url = URL(fileURLWithPath: path)
    var store: Store!
    report("Open the database", try time { store = try Store(url: url) }, target: 20)
    let count = try store.noteCount()
    print("  (\(count) notes)")
    let current = store.currentNoteID
    report("Load the open note", try time { _ = try store.note(id: current ?? 1) }, target: 5)
    report("First sidebar page (200 rows)", try time { _ = try store.notes(limit: 200) }, target: 10)
    let page = try store.notes(limit: 200)
    report("Next sidebar page", try time { _ = try store.notes(limit: 200, after: NoteCursor(after: page.last!)) }, target: 10)
    var rng = SplitMix64(state: 7)
    report("Open a random older note", try time(25) { _ = try store.note(id: NoteID(rng.int(1...count))) }, target: 16)
    let long = try store.notes(limit: 2000).max { $0.versionCount < $1.versionCount }!
    report("List versions of a long note (\(long.versionCount))", try time { _ = try store.versions(noteID: long.id) }, target: 5)
    let version = try store.versions(noteID: long.id).last!
    report("Open a version", try time { _ = try store.version(id: version.id) }, target: 5)

    print("  Search all notes (first 200 results, newest first):")
    for (label, query) in [
        ("  common word \"the\"", FindQuery("the")),
        ("  word \"coffee\"", FindQuery("coffee")),
        ("  phrase \"black coffee\"", FindQuery("black coffee")),
        ("  rare word \"zyzzyva\"", FindQuery("zyzzyva")),
        ("  whole word \"art\"", FindQuery("art", options: FindOptions(wholeWord: true))),
        ("  two letters \"qx\" (no index, full scan)", FindQuery("qx")),
        ("  regex \"zyzz\\w+\" (no index, full scan)", FindQuery("zyzz\\w+", options: FindOptions(regex: true))),
    ] {
        let indexed = !query.options.regex && query.text.count >= 3
        report(label, try time(3) { _ = try store.search(query, limit: 200) }, target: indexed ? 50 : nil)
    }

    var rngText = SplitMix64(state: 9)
    let big = makeText(words: 100_000, rng: &rngText) as NSString
    report("Find \"the\" in a 100,000-word note", try time { _ = try FindEngine.matches(of: FindQuery("the"), in: big) }, target: 50)
    report("Count words in a 100,000-word note", time { _ = WordCount.count(big as String) }, target: 50)
    report("Save a 100,000-word note", try time(5) {
        try store.updateText(noteID: long.id, text: (big as String) + String(rng.next()))
    }, target: nil)

    print(failures == 0 ? "All targets met." : "\(failures) over target.")
    if failures > 0 { exit(1) }
}

setvbuf(stdout, nil, _IOLBF, 0)

switch CommandLine.arguments.dropFirst().first {
case "seed": try seed()
case "measure": try measure()
default: print("usage: blktxt-bench seed|measure --db PATH [--years N] [--words-per-day N]")
}
