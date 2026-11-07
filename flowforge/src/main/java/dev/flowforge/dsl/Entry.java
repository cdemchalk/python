package dev.flowforge.dsl;

/**
 * A statement plus the formatting needed to write it back exactly.
 *
 * @param raw             original source text (may span lines); null once the statement was edited,
 *                        in which case the writer regenerates it
 * @param line            1-based source line (0 for statements added by edits)
 * @param indent          leading whitespace to keep when regenerating
 * @param trailingComment trailing {@code #! ...} comment to keep when regenerating, or null
 */
public record Entry(Stmt stmt, String raw, int line, String indent, String trailingComment) {
    public Entry {
        if (indent == null) indent = "";
    }

    public static Entry of(Stmt stmt) { return new Entry(stmt, null, 0, "", null); }

    /** Same formatting, new content: the writer regenerates the text. */
    public Entry replace(Stmt s) { return new Entry(s, null, line, indent, trailingComment); }

    public boolean dirty() { return raw == null; }
}
