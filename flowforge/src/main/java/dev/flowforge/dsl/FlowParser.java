package dev.flowforge.dsl;

import dev.flowforge.model.Colors;
import dev.flowforge.model.Direction;
import dev.flowforge.model.EdgeStyle;
import dev.flowforge.model.NodeType;

import java.util.ArrayList;
import java.util.List;
import java.util.Locale;

/**
 * Parses .flow text into a {@link FlowDocument}. The parser is line oriented; only {@code group}/{@code lane}
 * member lists may span several lines. Errors are collected (one per bad statement) and thrown together.
 */
public final class FlowParser {
    private static final int MAX_ERRORS = 25;

    private final String[] lines;
    private final List<Entry> entries = new ArrayList<>();
    private final List<ParseError> errors = new ArrayList<>();
    private int idx;

    private FlowParser(String[] lines) { this.lines = lines; }

    /** Parses and resolves the document; throws if there are syntax or semantic errors. */
    public static FlowDocument parse(String text) {
        FlowDocument doc = parseSyntax(text);
        doc.toDiagram(); // throws on semantic errors
        return doc;
    }

    /** Parses syntax only (no reference checks). */
    public static FlowDocument parseSyntax(String text) {
        String sep = text.contains("\r\n") ? "\r\n" : "\n";
        String norm = text.replace("\r\n", "\n");
        boolean trailingNewline = norm.endsWith("\n");
        String body = trailingNewline ? norm.substring(0, norm.length() - 1) : norm;
        String[] lines = norm.isEmpty() ? new String[0] : body.split("\n", -1);
        FlowParser p = new FlowParser(lines);
        p.run();
        if (!p.errors.isEmpty()) throw new FlowParseException(p.errors);
        return new FlowDocument(p.entries, sep, trailingNewline || norm.isEmpty());
    }

    private void run() {
        for (idx = 0; idx < lines.length && errors.size() < MAX_ERRORS; idx++) {
            String line = lines[idx];
            try {
                parseLine(line);
            } catch (SyntaxError e) {
                errors.add(e.error);
            }
        }
    }

    // ---------------------------------------------------------------- statements

    private void parseLine(String line) {
        int lineNo = idx + 1;
        int indentLen = 0;
        while (indentLen < line.length() && Character.isWhitespace(line.charAt(indentLen))) indentLen++;
        String indent = line.substring(0, indentLen);
        int commentAt = findComment(line, lineNo);
        String content = (commentAt < 0 ? line : line.substring(0, commentAt)).stripTrailing();
        String trailing = commentAt < 0 ? null : line.substring(commentAt).stripTrailing();
        if (content.isBlank()) {
            Stmt s = trailing == null ? new Stmt.Blank() : new Stmt.Comment(trailing);
            entries.add(new Entry(s, line, lineNo, indent, null));
            return;
        }
        Cursor c = new Cursor(line, content.length(), lineNo, indentLen);
        int startIdx = idx;
        Stmt stmt = statement(c);
        String raw = line;
        if (idx > startIdx) { // multi-line group: raw spans lines
            StringBuilder sb = new StringBuilder(line);
            for (int i = startIdx + 1; i <= idx; i++) sb.append('\n').append(lines[i]);
            raw = sb.toString();
        }
        entries.add(new Entry(stmt, raw, lineNo, indent, trailing));
    }

    private Stmt statement(Cursor c) {
        int start = c.pos;
        String w = c.peekWord();
        switch (w) {
            case "title" -> {
                c.pos += w.length();
                c.ws();
                if (c.atEnd()) throw c.error("'title' needs text, e.g. title \"Order flow\"");
                return new Stmt.Title(restText(c));
            }
            case "direction" -> {
                c.pos += w.length();
                c.ws();
                int at = c.pos;
                String d = c.word();
                try {
                    Direction dir = Direction.valueOf(d.toUpperCase(Locale.ROOT));
                    c.expectEnd("direction");
                    return new Stmt.DirectionStmt(dir);
                } catch (IllegalArgumentException e) {
                    throw c.error(at, "unknown direction '" + d + "' (expected TB, LR, BT or RL)");
                }
            }
            case "theme" -> {
                c.pos += w.length();
                c.ws();
                int at = c.pos;
                String t = c.word().toLowerCase(Locale.ROOT);
                if (!t.equals("light") && !t.equals("dark"))
                    throw c.error(at, "unknown theme '" + t + "' (expected light or dark)");
                c.expectEnd("theme");
                return new Stmt.ThemeStmt(t);
            }
            case "@pos" -> {
                c.pos += w.length();
                c.ws();
                String id = c.ident("node id after @pos");
                c.ws();
                double x = c.number();
                c.ws();
                if (c.peek() == ',') { c.pos++; c.ws(); }
                double y = c.number();
                c.expectEnd("@pos");
                return new Stmt.PosDecl(id, x, y);
            }
            case "group", "lane" -> { return group(c, w.equals("lane")); }
            default -> {
                var type = NodeType.fromKeyword(w);
                if (type.isPresent()) {
                    int save = c.pos;
                    c.pos += w.length();
                    c.ws();
                    boolean isEdge = arrowAt(c) != null;
                    c.pos = save;
                    if (!isEdge) return nodeDecl(c, type.get());
                }
                if (w.isEmpty())
                    throw c.error(start, "unexpected '" + c.peek() + "'; expected a statement such as "
                            + "'step id \"Label\"' or 'a -> b'");
                return edgeChain(c);
            }
        }
    }

    private Stmt nodeDecl(Cursor c, NodeType type) {
        c.pos += type.keyword().length();
        c.ws();
        String id = null, label = null, color = null;
        int at = c.pos;
        if (!c.atEnd() && Ids.isIdChar(c.peek())) { id = c.ident("node id"); c.ws(); }
        if (!c.atEnd() && c.peek() == '"') { label = c.string(); c.ws(); }
        if (!c.atEnd() && c.peek() == '#') { color = c.color(); c.ws(); }
        if (!c.atEnd()) {
            if (c.peek() == '"') throw c.error("a node has one label; join the text or use \\n for a line break");
            throw c.error("unexpected '" + c.rest() + "' in " + type.keyword()
                    + " declaration (expected: " + type.keyword() + " [id] [\"label\"] [#color])");
        }
        if (id == null && label == null && !type.keywordIsDefaultId())
            throw c.error(at, "expected an id or \"label\" after '" + type.keyword() + "'");
        if (id == null) {
            id = type.keywordIsDefaultId() ? type.keyword() : Ids.slug(label);
            if (id.isEmpty())
                throw c.error(at, "cannot derive an id from this label; add one: " + type.keyword() + " my_id \""
                        + label + "\"");
        }
        return new Stmt.NodeDecl(type, id, label, color);
    }

    private Stmt edgeChain(Cursor c) {
        int start = c.pos;
        List<String> nodes = new ArrayList<>();
        List<EdgeStyle> arrows = new ArrayList<>();
        nodes.add(c.ident("node id"));
        while (true) {
            c.ws();
            if (c.atEnd() || c.peek() == ':') break;
            EdgeStyle st = arrowAt(c);
            if (st == null) {
                if (nodes.size() == 1)
                    throw c.error(start, "unknown statement '" + nodes.get(0) + "'; expected a node type ("
                            + "start, end, step, decide, db, doc, note), title, direction, theme, group, lane, "
                            + "@pos, or an edge like 'a -> b'");
                throw c.error("expected '->', '-.->' or '==>' after '" + nodes.get(nodes.size() - 1) + "'");
            }
            c.pos += arrowLen(c);
            c.ws();
            if (c.atEnd()) throw c.error("expected a node id after the arrow");
            nodes.add(c.ident("node id after the arrow"));
            arrows.add(st);
        }
        if (nodes.size() == 1)
            throw c.error(c.pos, "expected '->' after '" + nodes.get(0) + "'");
        String label = null;
        if (!c.atEnd() && c.peek() == ':') {
            c.pos++;
            c.ws();
            if (c.atEnd()) throw c.error("expected an edge label after ':'");
            label = restText(c);
        }
        return new Stmt.EdgeChain(nodes, arrows, label);
    }

    private Stmt group(Cursor c, boolean lane) {
        String kw = lane ? "lane" : "group";
        int start = c.pos;
        c.pos += kw.length();
        c.ws();
        String id = null, label = null, color = null;
        if (!c.atEnd() && Ids.isIdChar(c.peek())) { id = c.ident("group id"); c.ws(); }
        if (!c.atEnd() && c.peek() == '"') { label = c.string(); c.ws(); }
        if (!c.atEnd() && c.peek() == '#') { color = c.color(); c.ws(); }
        if (id == null && label == null) throw c.error(start, kw + " needs an id or \"label\"");
        if (c.atEnd() || c.peek() != '{')
            throw c.error("expected '{' to start the member list, e.g. " + kw + " \"Name\" { a, b }");
        c.pos++;
        List<String> members = new ArrayList<>();
        boolean multiline = false;
        int headerIdx = idx;
        if (!membersUntilBrace(c, members)) {
            // continue on following lines
            multiline = true;
            int close = -1;
            for (int j = idx + 1; j < lines.length; j++) {
                String l = lines[j];
                int cm = findComment(l, j + 1);
                if ((cm < 0 ? l : l.substring(0, cm)).contains("}")) { close = j; break; }
            }
            if (close < 0) throw c.error(start, "unclosed '{' in " + kw + "; add a closing '}'");
            idx = close;
            for (int j = headerIdx + 1; j <= close; j++) {
                String l = lines[j];
                int cm = findComment(l, j + 1);
                String content = (cm < 0 ? l : l.substring(0, cm)).stripTrailing();
                Cursor mc = new Cursor(l, content.length(), j + 1, 0);
                boolean closed = membersUntilBrace(mc, members);
                if (closed) break;
            }
        }
        if (id == null) {
            id = Ids.slug(label);
            if (id.isEmpty()) throw c.error(start, "cannot derive a group id from this label; add one");
        }
        return new Stmt.GroupDecl(id, label, color, lane, members, multiline);
    }

    /** Reads "a, b c" up to '}' (returns true) or end of line (returns false). */
    private boolean membersUntilBrace(Cursor c, List<String> out) {
        while (true) {
            c.ws();
            if (c.atEnd()) return false;
            char ch = c.peek();
            if (ch == '}') {
                c.pos++;
                c.expectEnd("group");
                return true;
            }
            if (ch == ',') { c.pos++; continue; }
            out.add(c.ident("group member id"));
        }
    }

    // ---------------------------------------------------------------- lexical helpers

    private static String restText(Cursor c) {
        if (c.peek() == '"') {
            String s = c.string();
            c.expectEnd("text");
            return s;
        }
        String t = c.rest().strip();
        c.pos = c.end;
        return t;
    }

    private static EdgeStyle arrowAt(Cursor c) {
        if (c.startsWith("-.->")) return EdgeStyle.DASHED;
        if (c.startsWith("-->") || c.startsWith("->")) return EdgeStyle.SOLID;
        if (c.startsWith("==>")) return EdgeStyle.THICK;
        return null;
    }

    private static int arrowLen(Cursor c) {
        if (c.startsWith("-.->")) return 4;
        if (c.startsWith("-->") || c.startsWith("==>")) return 3;
        return 2;
    }

    /** Index of {@code #!} outside a quoted string, or -1. */
    static int findComment(String line, int lineNo) {
        boolean inStr = false;
        for (int i = 0; i < line.length(); i++) {
            char ch = line.charAt(i);
            if (inStr) {
                if (ch == '\\') i++;
                else if (ch == '"') inStr = false;
            } else if (ch == '"') {
                inStr = true;
            } else if (ch == '#' && i + 1 < line.length() && line.charAt(i + 1) == '!') {
                return i;
            }
        }
        return -1;
    }

    static final class SyntaxError extends RuntimeException {
        final ParseError error;

        SyntaxError(ParseError error) {
            super(error.message(), null, false, false);
            this.error = error;
        }
    }

    /** Character cursor over one line. {@code end} excludes any trailing comment. */
    static final class Cursor {
        final String s;
        final int end;
        final int lineNo;
        int pos;

        Cursor(String s, int end, int lineNo, int pos) {
            this.s = s;
            this.end = end;
            this.lineNo = lineNo;
            this.pos = pos;
        }

        boolean atEnd() { return pos >= end; }

        char peek() { return atEnd() ? '\0' : s.charAt(pos); }

        boolean startsWith(String t) { return pos + t.length() <= end && s.startsWith(t, pos); }

        void ws() { while (!atEnd() && Character.isWhitespace(s.charAt(pos))) pos++; }

        String rest() { return s.substring(pos, end); }

        String peekWord() {
            int i = pos;
            if (i < end && s.charAt(i) == '@') i++;
            while (i < end && Ids.isIdChar(s.charAt(i))) i++;
            return s.substring(pos, i);
        }

        String word() {
            String w = peekWord();
            if (w.isEmpty()) throw error("expected a word");
            pos += w.length();
            return w;
        }

        String ident(String what) {
            int i = pos;
            while (i < end && Ids.isIdChar(s.charAt(i))) i++;
            if (i == pos) {
                if (atEnd()) throw error("expected " + what);
                throw error("expected " + what + " but found '" + peek() + "' (ids use letters, digits and _)");
            }
            String id = s.substring(pos, i);
            pos = i;
            return id;
        }

        double number() {
            int start = pos;
            if (peek() == '-' || peek() == '+') pos++;
            while (!atEnd() && (Character.isDigit(peek()) || peek() == '.')) pos++;
            String t = s.substring(start, pos);
            try {
                return Double.parseDouble(t);
            } catch (NumberFormatException e) {
                pos = start;
                throw error("expected a number" + (t.isEmpty() ? "" : " but found '" + t + "'")
                        + ", e.g. @pos node 120,240");
            }
        }

        String string() {
            int start = pos;
            pos++; // opening quote
            StringBuilder sb = new StringBuilder();
            while (pos < end) {
                char ch = s.charAt(pos++);
                if (ch == '"') return sb.toString();
                if (ch == '\\' && pos < end) {
                    char n = s.charAt(pos++);
                    switch (n) {
                        case 'n' -> sb.append('\n');
                        case '"' -> sb.append('"');
                        case '\\' -> sb.append('\\');
                        default -> sb.append('\\').append(n);
                    }
                } else {
                    sb.append(ch);
                }
            }
            throw error(start, "unterminated string; add a closing \"");
        }

        String color() {
            int start = pos;
            pos++; // '#'
            int i = pos;
            while (i < end && Character.isLetterOrDigit(s.charAt(i))) i++;
            String c = s.substring(pos, i);
            pos = i;
            if (!Colors.isValid(c))
                throw error(start, "unknown color '#" + c + "' (use " + String.join(", ", Colors.NAMES)
                        + ", or a hex value like #3366ff)");
            return c;
        }

        void expectEnd(String what) {
            ws();
            if (!atEnd()) throw error("unexpected '" + rest().strip() + "' after " + what);
        }

        SyntaxError error(String msg) { return error(pos, msg); }

        SyntaxError error(int at, String msg) {
            return new SyntaxError(new ParseError(lineNo, at + 1, msg, s));
        }
    }
}
