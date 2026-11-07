package dev.flowforge.dsl;

/** A located parse or semantic error. Line and column are 1-based. */
public record ParseError(int line, int column, String message, String sourceLine) {

    /** Compiler-style message with a caret under the offending column. */
    public String format(String fileName) {
        StringBuilder sb = new StringBuilder();
        sb.append(fileName == null ? "<input>" : fileName).append(':').append(line).append(':').append(column)
                .append(": error: ").append(message);
        if (sourceLine != null && !sourceLine.isBlank()) {
            sb.append('\n').append("    ").append(sourceLine).append('\n').append("    ");
            for (int i = 1; i < column && i <= sourceLine.length(); i++)
                sb.append(sourceLine.charAt(i - 1) == '\t' ? '\t' : ' ');
            sb.append('^');
        }
        return sb.toString();
    }
}
