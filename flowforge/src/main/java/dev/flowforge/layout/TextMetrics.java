package dev.flowforge.layout;

/**
 * Font-independent text width estimate for a typical sans-serif UI font. Using a fixed table keeps layouts
 * identical across machines (and between SVG in a browser and PNG from Java2D).
 */
public final class TextMetrics {
    private TextMetrics() {}

    public static double width(String text, double fontSize) {
        double em = 0;
        for (int i = 0; i < text.length(); i++) em += charWidth(text.charAt(i));
        return em * fontSize;
    }

    public static double maxLineWidth(String text, double fontSize) {
        double w = 0;
        for (String line : lines(text)) w = Math.max(w, width(line, fontSize));
        return w;
    }

    public static String[] lines(String text) { return text.split("\n", -1); }

    static double charWidth(char c) {
        if (c == ' ') return 0.28;
        if ("il.,:;'|!".indexOf(c) >= 0) return 0.27;
        if ("fjtrI()[]{}/\\-\"".indexOf(c) >= 0) return 0.36;
        if ("mwMW@".indexOf(c) >= 0) return 0.88;
        if (Character.isUpperCase(c)) return 0.67;
        if (Character.isDigit(c)) return 0.56;
        if (Character.isLowerCase(c)) return 0.53;
        if (c > 0x2E80) return 1.0; // CJK and similar
        return 0.6;
    }
}
