import SwiftUI

// MARK: - Palette

/// Colors for code tokens in diffs. Themes may override; otherwise a Dark+/Light+ style palette is used.
struct SyntaxPalette: Hashable {
    let keyword: Color
    let string: Color
    let comment: Color
    let number: Color
    let type: Color
    let function: Color
    let annotation: Color
    let property: Color
    /// Bracket colors by nesting depth.
    let brackets: [Color]
    /// `= == ? : + -` etc.; nil leaves them plain.
    var operators: Color? = nil
    /// `; , .` and generic `<>`; nil leaves them plain.
    var punctuation: Color? = nil
    var italicComments = false
    /// `int`, `boolean`, `double`… colored as types instead of keywords.
    var primitivesAsTypes = false

    static let standard = SyntaxPalette(
        keyword: .adaptive(light: .hex(0x0000FF), dark: .hex(0x569CD6)),
        string: .adaptive(light: .hex(0xA31515), dark: .hex(0xCE9178)),
        comment: .adaptive(light: .hex(0x008000), dark: .hex(0x7CA668)),
        number: .adaptive(light: .hex(0x098658), dark: .hex(0xB5CEA8)),
        type: .adaptive(light: .hex(0x267F99), dark: .hex(0x4EC9B0)),
        function: .adaptive(light: .hex(0x795E26), dark: .hex(0xDCDCAA)),
        annotation: .adaptive(light: .hex(0xAF00DB), dark: .hex(0xC586C0)),
        property: .adaptive(light: .hex(0x0451A5), dark: .hex(0x9CDCFE)),
        brackets: [.adaptive(light: .hex(0x0431FA), dark: .hex(0xFFD700)),
                   .adaptive(light: .hex(0x319331), dark: .hex(0xDA70D6)),
                   .adaptive(light: .hex(0x7B3814), dark: .hex(0x179FFF))]
    )

    /// Monokai Pro as in JetBrains/VS Code: pink keywords, cyan types, green methods, cyan annotations, purple constants, grey punctuation.
    static let monokaiPro = SyntaxPalette(
        keyword: .hex(0xFD6883), string: .hex(0xFFD866), comment: .hex(0x727072),
        number: .hex(0xA8A9EB), type: .hex(0x85DACC), function: .hex(0xADDA78),
        annotation: .hex(0x85DACC), property: .hex(0x85DACC),
        brackets: [.hex(0x939293)],
        operators: .hex(0xFD6883), punctuation: .hex(0x939293),
        italicComments: true, primitivesAsTypes: true
    )

    /// Settings › Editor › Code colors: "" follows the app theme.
    static let key = "syntaxTheme"
    static let choices: [(id: String, name: String)] = [("", "Match app theme"), ("standard", "Default"), ("monokai-pro", "Monokai Pro")]

    static func named(_ id: String) -> SyntaxPalette {
        switch id {
        case "standard": return .standard
        case "monokai-pro": return .monokaiPro
        default: return Theme.current.syntax ?? .standard
        }
    }

    static var current: SyntaxPalette { named(UserDefaults.standard.string(forKey: key) ?? "") }
}

// MARK: - Languages

/// What the highlighter needs to know about a language.
struct SyntaxLanguage {
    var keywords: Set<String> = []
    var lineComments: [String] = []
    var blockComments = false
    var backtickStrings = false
    var caseInsensitive = false
    /// `name:` at the start of a key (YAML, JSON, CSS) is a property.
    var keyColon = false
    var markup = false

    static let plain = SyntaxLanguage()
    static let primitives: Set<String> = ["int", "long", "short", "byte", "char", "boolean", "bool", "double", "float", "decimal", "string", "Int", "Double", "Bool", "String", "i32", "i64", "u8", "u32", "u64", "usize", "f64", "str", "int64", "float64", "error"]

    static func forPath(_ path: String?) -> SyntaxLanguage {
        guard let path else { return .plain }
        let name = (path as NSString).lastPathComponent.lowercased()
        if name == "dockerfile" || name.hasPrefix("dockerfile.") { return dockerfile }
        if name == "makefile" { return shell }
        switch (name as NSString).pathExtension {
        case "java", "groovy", "gradle", "scala": return cLike(java)
        case "kt", "kts": return cLike(kotlin)
        case "swift": return cLike(swift)
        case "js", "jsx", "mjs", "cjs", "ts", "tsx", "vue", "svelte": return cLike(javascript, backticks: true)
        case "go": return cLike(go, backticks: true)
        case "rs": return cLike(rust)
        case "cs": return cLike(csharp)
        case "c", "h", "cpp", "cc", "cxx", "hpp", "m", "mm": return cLike(cFamily)
        case "dart": return cLike(java.union(["final", "late", "required", "dynamic", "async", "await", "Future"]))
        case "php": return SyntaxLanguage(keywords: php, lineComments: ["//", "#"], blockComments: true)
        case "py", "pyi": return SyntaxLanguage(keywords: python, lineComments: ["#"])
        case "rb", "rake", "gemspec": return SyntaxLanguage(keywords: ruby, lineComments: ["#"])
        case "sh", "bash", "zsh", "fish", "env": return shell
        case "sql": return SyntaxLanguage(keywords: sql, lineComments: ["--"], blockComments: true, caseInsensitive: true)
        case "yml", "yaml", "toml", "ini", "properties", "conf":
            return SyntaxLanguage(keywords: ["true", "false", "null", "yes", "no", "on", "off"], lineComments: ["#"], keyColon: true)
        case "json", "jsonc": return SyntaxLanguage(keywords: ["true", "false", "null"], lineComments: ["//"], keyColon: true)
        case "css", "scss", "less", "sass":
            return SyntaxLanguage(keywords: ["!important", "@media", "@import", "@include", "@mixin"], lineComments: ["//"], blockComments: true, keyColon: true)
        case "xml", "html", "htm", "xhtml", "svg", "plist", "xib", "storyboard", "csproj", "pom":
            return SyntaxLanguage(markup: true)
        default: return .plain
        }
    }

    private static func cLike(_ keywords: Set<String>, backticks: Bool = false) -> SyntaxLanguage {
        SyntaxLanguage(keywords: keywords, lineComments: ["//"], blockComments: true, backtickStrings: backticks)
    }

    private static let shell = SyntaxLanguage(keywords: ["if", "then", "else", "elif", "fi", "case", "esac", "for", "while", "until", "do", "done", "in", "function", "return", "local", "export", "echo", "exit", "set", "unset", "readonly", "source", "true", "false"], lineComments: ["#"])
    private static let dockerfile = SyntaxLanguage(keywords: ["FROM", "RUN", "CMD", "LABEL", "EXPOSE", "ENV", "ADD", "COPY", "ENTRYPOINT", "VOLUME", "USER", "WORKDIR", "ARG", "ONBUILD", "STOPSIGNAL", "HEALTHCHECK", "SHELL", "AS"], lineComments: ["#"])

    private static let java: Set<String> = ["abstract", "assert", "boolean", "break", "byte", "case", "catch", "char", "class", "const", "continue", "default", "do", "double", "else", "enum", "extends", "final", "finally", "float", "for", "if", "implements", "import", "instanceof", "int", "interface", "long", "native", "new", "package", "private", "protected", "public", "return", "short", "static", "super", "switch", "synchronized", "this", "throw", "throws", "transient", "try", "void", "volatile", "while", "var", "record", "yield", "true", "false", "null", "sealed", "permits", "def", "val", "object", "trait", "with", "match"]
    private static let kotlin: Set<String> = ["fun", "val", "var", "when", "object", "companion", "data", "sealed", "override", "open", "internal", "lateinit", "init", "is", "in", "as", "typealias", "suspend", "inline", "reified", "null", "true", "false", "this", "super", "return", "if", "else", "for", "while", "do", "try", "catch", "finally", "throw", "class", "interface", "import", "package", "private", "public", "protected", "abstract", "enum", "constructor", "break", "continue", "const", "annotation"]
    private static let swift: Set<String> = ["associatedtype", "class", "deinit", "enum", "extension", "fileprivate", "func", "import", "init", "inout", "internal", "let", "open", "operator", "private", "protocol", "public", "rethrows", "static", "struct", "subscript", "typealias", "var", "break", "case", "continue", "default", "defer", "do", "else", "fallthrough", "for", "guard", "if", "in", "repeat", "return", "switch", "where", "while", "as", "catch", "false", "is", "nil", "super", "self", "Self", "throw", "throws", "true", "try", "async", "await", "actor", "some", "any", "mutating", "nonmutating", "override", "final", "lazy", "weak", "unowned", "convenience", "required", "indirect", "get", "set", "willSet", "didSet"]
    private static let javascript: Set<String> = ["break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete", "do", "else", "export", "extends", "finally", "for", "function", "if", "import", "in", "instanceof", "new", "return", "super", "switch", "this", "throw", "try", "typeof", "var", "void", "while", "with", "yield", "let", "static", "async", "await", "of", "null", "undefined", "true", "false", "enum", "implements", "interface", "private", "protected", "public", "type", "as", "from", "readonly", "declare", "namespace", "abstract", "keyof", "never", "unknown", "any", "number", "string", "boolean"]
    private static let go: Set<String> = ["break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "for", "func", "go", "goto", "if", "import", "interface", "map", "package", "range", "return", "select", "struct", "switch", "type", "var", "nil", "true", "false", "iota", "string", "int", "int64", "bool", "error", "byte", "float64"]
    private static let rust: Set<String> = ["as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern", "false", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return", "self", "Self", "static", "struct", "super", "trait", "true", "type", "unsafe", "use", "where", "while", "i32", "i64", "u8", "u32", "u64", "usize", "f64", "bool", "str"]
    private static let csharp: Set<String> = ["abstract", "as", "async", "await", "base", "bool", "break", "case", "catch", "class", "const", "continue", "decimal", "default", "do", "double", "else", "enum", "event", "false", "finally", "float", "for", "foreach", "get", "if", "in", "int", "interface", "internal", "is", "long", "namespace", "new", "null", "object", "out", "override", "private", "protected", "public", "readonly", "record", "ref", "return", "sealed", "set", "static", "string", "struct", "switch", "this", "throw", "true", "try", "using", "var", "virtual", "void", "while"]
    private static let cFamily: Set<String> = ["auto", "bool", "break", "case", "char", "class", "const", "constexpr", "continue", "default", "delete", "do", "double", "else", "enum", "extern", "false", "float", "for", "goto", "if", "inline", "int", "long", "namespace", "new", "nullptr", "NULL", "private", "protected", "public", "return", "short", "signed", "sizeof", "static", "struct", "switch", "template", "this", "true", "typedef", "typename", "union", "unsigned", "using", "virtual", "void", "volatile", "while", "#include", "#define", "#if", "#ifdef", "#ifndef", "#endif", "#else", "#pragma", "#import", "@interface", "@implementation", "@end", "@property", "nil", "self", "YES", "NO"]
    private static let php: Set<String> = ["abstract", "and", "array", "as", "break", "case", "catch", "class", "const", "continue", "default", "do", "echo", "else", "elseif", "extends", "false", "final", "finally", "fn", "for", "foreach", "function", "if", "implements", "interface", "match", "namespace", "new", "null", "or", "private", "protected", "public", "readonly", "return", "self", "static", "switch", "throw", "trait", "true", "try", "use", "while", "string", "int", "bool", "float", "void", "mixed"]
    private static let python: Set<String> = ["False", "None", "True", "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif", "else", "except", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "nonlocal", "not", "or", "pass", "raise", "return", "try", "while", "with", "yield", "self", "match", "case"]
    private static let ruby: Set<String> = ["alias", "and", "begin", "break", "case", "class", "def", "defined?", "do", "else", "elsif", "end", "ensure", "false", "for", "if", "in", "module", "next", "nil", "not", "or", "redo", "rescue", "retry", "return", "self", "super", "then", "true", "undef", "unless", "until", "when", "while", "yield", "require", "attr_accessor", "attr_reader", "private"]
    private static let sql: Set<String> = ["select", "from", "where", "and", "or", "not", "insert", "into", "values", "update", "set", "delete", "create", "table", "alter", "drop", "index", "join", "left", "right", "inner", "outer", "on", "as", "group", "by", "order", "having", "limit", "offset", "null", "is", "in", "like", "between", "distinct", "union", "all", "primary", "key", "foreign", "references", "default", "exists", "case", "when", "then", "else", "end", "begin", "commit", "rollback", "view", "with", "returning", "cascade", "constraint", "unique", "check", "int", "integer", "bigint", "varchar", "text", "boolean", "date", "timestamp", "add", "column", "if", "asc", "desc", "count", "true", "false"]
}

// MARK: - Highlighter

/// Colors one line of code. Works per line, so block comments only color lines that start or continue with `/*` or `*`.
enum SyntaxHighlighter {
    static func highlight(_ text: String, language: SyntaxLanguage, palette: SyntaxPalette) -> AttributedString {
        guard language.markup || !language.keywords.isEmpty || !language.lineComments.isEmpty else {
            return AttributedString(text)
        }
        var out = AttributedString()
        func emit(_ s: Substring, _ color: Color?) {
            var part = AttributedString(String(s))
            if let color { part.foregroundColor = color }
            if palette.italicComments, color == palette.comment { part.inlinePresentationIntent = .emphasized }
            out.append(part)
        }

        // A middle line of a /* … */ or /** … */ block.
        if language.blockComments {
            let trimmed = text.drop { $0 == " " }
            if trimmed.hasPrefix("* ") || trimmed == "*" || trimmed.hasPrefix("*/") || trimmed.hasPrefix("**") {
                emit(Substring(text), palette.comment)
                return out
            }
        }

        if language.markup { return markup(text, palette: palette) }

        let chars = Array(text)
        let n = chars.count
        var i = 0
        var depth = 0
        var genericDepth = 0
        var plainStart = 0

        func flushPlain(to end: Int) {
            if plainStart < end { emit(Substring(String(chars[plainStart..<end])), nil) }
        }
        func token(_ start: Int, _ end: Int, _ color: Color?) {
            flushPlain(to: start)
            emit(Substring(String(chars[start..<end])), color)
            plainStart = end
        }
        func starts(_ s: String, at k: Int) -> Bool {
            let p = Array(s)
            guard k + p.count <= n else { return false }
            return Array(chars[k..<k + p.count]) == p
        }
        func isIdent(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" || c == "$" }
        func nextNonSpace(_ k: Int) -> Character? {
            var j = k
            while j < n, chars[j] == " " || chars[j] == "\t" { j += 1 }
            return j < n ? chars[j] : nil
        }

        while i < n {
            let c = chars[i]

            // Line comment.
            if let marker = language.lineComments.first(where: { starts($0, at: i) }),
               marker != "#" || i == 0 || chars[i - 1] == " " || chars[i - 1] == "\t" {
                token(i, n, palette.comment)
                i = n
                break
            }
            // Block comment on one line (or running to the end).
            if language.blockComments, starts("/*", at: i) {
                var j = i + 2
                while j < n, !starts("*/", at: j) { j += 1 }
                j = min(n, j + 2)
                token(i, j, palette.comment)
                i = j
                continue
            }
            // Strings.
            if c == "\"" || c == "'" || (c == "`" && language.backtickStrings) {
                var j = i + 1
                while j < n, chars[j] != c {
                    j += chars[j] == "\\" ? 2 : 1
                }
                j = min(n, j + 1)
                let isKey = language.keyColon && nextNonSpace(j) == ":"
                token(i, j, isKey ? palette.property : palette.string)
                i = j
                continue
            }
            // Numbers (and CSS hex colors).
            if c.isNumber || (c == "#" && language.keyColon && i + 1 < n && chars[i + 1].isHexDigit),
               i == 0 || !isIdent(chars[i - 1]) {
                var j = i + 1
                while j < n, chars[j].isHexDigit || chars[j].isLetter || chars[j] == "." || chars[j] == "_" { j += 1 }
                token(i, j, palette.number)
                i = j
                continue
            }
            // Annotations / decorators / C preprocessor.
            if (c == "@" || c == "#"), i + 1 < n, chars[i + 1].isLetter {
                var j = i + 1
                while j < n, isIdent(chars[j]) || chars[j] == "." { j += 1 }
                let word = String(chars[i..<j])
                token(i, j, language.keywords.contains(word) ? palette.keyword : palette.annotation)
                i = j
                continue
            }
            // Words.
            if c.isLetter || c == "_" || c == "$" {
                var j = i + 1
                while j < n, isIdent(chars[j]) || (chars[j] == "?" && language.lineComments == ["#"]) { j += 1 }
                if j > i + 1, chars[j - 1] == "?" { j -= 1 }
                let word = String(chars[i..<j])
                let lookup = language.caseInsensitive ? word.lowercased() : word
                let color: Color?
                if palette.primitivesAsTypes, SyntaxLanguage.primitives.contains(lookup) {
                    color = palette.type
                } else if language.keywords.contains(lookup) {
                    color = palette.keyword
                } else if language.keyColon, nextNonSpace(j) == ":" {
                    color = palette.property
                } else if nextNonSpace(j) == "(" {
                    color = palette.function
                } else if word.count > 1, word.allSatisfy({ $0.isUppercase || $0.isNumber || $0 == "_" }), word.contains(where: \.isLetter) {
                    color = palette.number      // CONSTANT
                } else if c.isUppercase {
                    color = palette.type
                } else {
                    color = nil
                }
                token(i, j, color)
                i = j
                continue
            }
            // Brackets, colored by depth.
            if "([{".contains(c) {
                token(i, i + 1, palette.brackets[depth % palette.brackets.count])
                depth += 1
                i += 1
                continue
            }
            if ")]}".contains(c) {
                depth = max(0, depth - 1)
                token(i, i + 1, palette.brackets[depth % palette.brackets.count])
                i += 1
                continue
            }
            // Generic angle brackets: `List<String>`, `new ArrayList<>()`.
            if c == "<", i > 0, isIdent(chars[i - 1]), i + 1 < n, chars[i + 1].isUppercase || chars[i + 1] == ">" || chars[i + 1] == "?" {
                token(i, i + 1, palette.punctuation)
                genericDepth += 1
                i += 1
                continue
            }
            if c == ">", genericDepth > 0 {
                token(i, i + 1, palette.punctuation)
                genericDepth -= 1
                i += 1
                continue
            }
            if ";,.".contains(c), palette.punctuation != nil {
                token(i, i + 1, palette.punctuation)
                i += 1
                continue
            }
            if "=!<>?:+-*/%&|^~".contains(c), let op = palette.operators {
                var j = i + 1
                while j < n, "=!<>?:+-*/%&|^~".contains(chars[j]) { j += 1 }
                token(i, j, op)
                i = j
                continue
            }
            i += 1
        }
        flushPlain(to: n)
        return out
    }

    /// XML / HTML: tag names, attributes, values, comments.
    private static func markup(_ text: String, palette: SyntaxPalette) -> AttributedString {
        var out = AttributedString()
        func emit(_ s: String, _ color: Color?) {
            var part = AttributedString(s)
            if let color { part.foregroundColor = color }
            out.append(part)
        }
        let chars = Array(text)
        let n = chars.count
        var i = 0
        var inTag = false
        var expectName = false
        var plain = ""

        func flush() { if !plain.isEmpty { emit(plain, nil); plain = "" } }

        while i < n {
            let c = chars[i]
            if !inTag, c == "<", i + 3 < n, String(chars[i..<i + 4]) == "<!--" {
                var j = i + 4
                while j + 2 < n, String(chars[j..<j + 3]) != "-->" { j += 1 }
                j = min(n, j + 3)
                flush(); emit(String(chars[i..<j]), palette.comment); i = j
                continue
            }
            if c == "<" {
                flush()
                var j = i + 1
                if j < n, "/?!".contains(chars[j]) { j += 1 }
                emit(String(chars[i..<j]), palette.comment)
                inTag = true; expectName = true; i = j
                continue
            }
            if inTag, c == ">" || (c == "/" && i + 1 < n && chars[i + 1] == ">") || (c == "?" && i + 1 < n && chars[i + 1] == ">") {
                flush()
                let j = c == ">" ? i + 1 : i + 2
                emit(String(chars[i..<j]), palette.comment)
                inTag = false; i = j
                continue
            }
            if inTag, c == "\"" || c == "'" {
                flush()
                var j = i + 1
                while j < n, chars[j] != c { j += 1 }
                j = min(n, j + 1)
                emit(String(chars[i..<j]), palette.string); i = j
                continue
            }
            if inTag, c.isLetter || c == "_" {
                flush()
                var j = i + 1
                while j < n, chars[j].isLetter || chars[j].isNumber || "-_:.".contains(chars[j]) { j += 1 }
                emit(String(chars[i..<j]), expectName ? palette.keyword : palette.property)
                expectName = false; i = j
                continue
            }
            plain.append(c)
            i += 1
        }
        flush()
        return out
    }
}
