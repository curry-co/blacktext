import Foundation
import Testing
@testable import BlackTextCore

@Suite struct FindEngineTests {
    func find(_ query: String, in text: String, _ options: FindOptions = FindOptions()) throws -> [String] {
        let ns = text as NSString
        return try FindEngine.matches(of: FindQuery(query, options: options), in: ns).map { ns.substring(with: $0) }
    }

    @Test func literalIsCaseInsensitiveByDefault() throws {
        #expect(try find("coffee", in: "Coffee, coffee, COFFEE") == ["Coffee", "coffee", "COFFEE"])
        #expect(try find("coffee", in: "Coffee, coffee", FindOptions(matchCase: true)) == ["coffee"])
    }

    @Test func literalTreatsRegexCharactersLiterally() throws {
        #expect(try find("a.b", in: "a.b axb") == ["a.b"])
        #expect(try find("(x)", in: "f(x) = (x)") == ["(x)", "(x)"])
    }

    @Test func wholeWord() throws {
        let options = FindOptions(wholeWord: true)
        #expect(try find("cat", in: "cat concat cats cat.", options) == ["cat", "cat"])
        #expect(try find("c++", in: "c++ and c++11", options) == ["c++"])
        #expect(try find("café", in: "café cafés", options) == ["café"])
    }

    @Test func regexWithLineAnchors() throws {
        let options = FindOptions(regex: true)
        #expect(try find("^- (\\w+)", in: "- one\n- two\nnot - three", options) == ["- one", "- two"])
        #expect(try find("a*", in: "baaa", options) == ["aaa"])
    }

    @Test func invalidRegexThrows() {
        #expect(throws: FindError.invalidPattern) {
            try FindEngine.matches(of: FindQuery("(", options: FindOptions(regex: true)), in: "text")
        }
    }

    @Test func rangesAreUTF16() throws {
        let text = "🙂 coffee" as NSString
        let ranges = try FindEngine.matches(of: FindQuery("coffee"), in: text)
        #expect(ranges == [NSRange(location: 3, length: 6)])
    }

    @Test func replaceAllLiteral() throws {
        let result = try FindEngine.replaceAll(in: "a $1 a", query: FindQuery("a"), template: "$1")
        #expect(result.text == "$1 $1 $1")
        #expect(result.count == 2)
    }

    @Test func replaceAllRegexGroups() throws {
        let query = FindQuery("(\\w+)@(\\w+)", options: FindOptions(regex: true))
        let result = try FindEngine.replaceAll(in: "me@home you@work", query: query, template: "$2:$1")
        #expect(result.text == "home:me work:you")
    }

    @Test func replaceAllWholeWordTemplateIsLiteral() throws {
        let query = FindQuery("cat", options: FindOptions(wholeWord: true))
        let result = try FindEngine.replaceAll(in: "cat concat", query: query, template: "$0dog")
        #expect(result.text == "$0dog concat")
    }

    @Test func preserveCase() throws {
        let result = try FindEngine.replaceAll(in: "coffee Coffee COFFEE cOFfee", query: FindQuery("coffee"),
                                               template: "tea", preserveCase: true)
        #expect(result.text == "tea Tea TEA tea")
        #expect(FindEngine.applyCase(of: "Coffee", to: "iced tea") == "Iced tea")
        #expect(FindEngine.applyCase(of: "123", to: "Tea") == "Tea")
        #expect(FindEngine.applyCase(of: "I", to: "we") == "We")
    }

    @Test func replaceFirstOnly() throws {
        let result = try FindEngine.replaceFirst(in: "a a a", query: FindQuery("a"), template: "b")
        #expect(result.text == "b a a")
        #expect(result.count == 1)
    }
}
