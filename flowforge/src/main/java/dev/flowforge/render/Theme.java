package dev.flowforge.render;

import dev.flowforge.model.Colors;
import dev.flowforge.model.NodeType;

import java.util.Locale;
import java.util.Map;

/** Light and dark color schemes. All colors are #rrggbb. */
public record Theme(String name, String background, String text, String title, String edge, String labelBg,
                    String labelBorder, String labelText, String groupFill, String groupStroke, String groupText,
                    String laneFillA, String laneFillB, String laneStroke, String laneHeader, double shadowOpacity,
                    Swatch neutral, Swatch note, Map<String, Swatch> palette) {

    /** Fill, stroke and text color of one node color. */
    public record Swatch(String fill, String stroke, String text) {}

    public static Theme byName(String name) {
        if (name == null) return light();
        return switch (name.toLowerCase(Locale.ROOT)) {
            case "light" -> light();
            case "dark" -> dark();
            default -> throw new IllegalArgumentException("unknown theme '" + name + "' (expected light or dark)");
        };
    }

    public static Theme light() {
        return new Theme("light", "#ffffff", "#1f2933", "#111827", "#64748b", "#ffffff", "#d5dce6", "#334155",
                "#f5f7fa", "#d3dbe6", "#52606d", "#f8fafc", "#f1f5f9", "#dbe2ea", "#334155", 0.10,
                new Swatch("#ffffff", "#5b6b7f", "#1f2933"),
                new Swatch("#fff9db", "#d4b23f", "#5c4813"),
                Map.of(
                        "blue", new Swatch("#e8f0fe", "#3b6fd8", "#1d3d80"),
                        "green", new Swatch("#e5f6ec", "#2f9e5b", "#17532f"),
                        "amber", new Swatch("#fff3d6", "#d48f0c", "#6b4708"),
                        "red", new Swatch("#fdeaea", "#d64545", "#7a1f1f"),
                        "purple", new Swatch("#f1ebfd", "#7c4ddb", "#3f2378"),
                        "teal", new Swatch("#e1f5f5", "#1d9a9a", "#0f5050"),
                        "pink", new Swatch("#fde9f3", "#d4448c", "#74204a"),
                        "orange", new Swatch("#ffefe2", "#e0712b", "#73360f"),
                        "gray", new Swatch("#f1f3f5", "#868e96", "#343a40")));
    }

    public static Theme dark() {
        return new Theme("dark", "#0f141a", "#e6edf3", "#f3f6f9", "#8b98a9", "#161c24", "#3a4554", "#cdd6e0",
                "#151b23", "#2f3a48", "#9aa7b6", "#131920", "#171e27", "#2a3441", "#cdd6e0", 0.45,
                new Swatch("#1b222c", "#8794a6", "#e6edf3"),
                new Swatch("#302c17", "#c9ab45", "#f3e8bf"),
                Map.of(
                        "blue", new Swatch("#17253f", "#6d9cff", "#dbe6ff"),
                        "green", new Swatch("#132e22", "#4cc38a", "#d3f5e3"),
                        "amber", new Swatch("#33290f", "#f0b43c", "#fdecc8"),
                        "red", new Swatch("#361a1c", "#f07171", "#ffdcdc"),
                        "purple", new Swatch("#261d3c", "#a98bf5", "#ece4ff"),
                        "teal", new Swatch("#112f30", "#3cc6c6", "#d2f6f6"),
                        "pink", new Swatch("#341a29", "#f07ab5", "#ffdff0"),
                        "orange", new Swatch("#35211a", "#f59a5c", "#ffe6d4"),
                        "gray", new Swatch("#22272d", "#9aa3ad", "#e9ecef")));
    }

    public Swatch swatch(String color, NodeType type) {
        if (color == null) return type == NodeType.NOTE ? note : neutral;
        Swatch s = palette.get(color);
        if (s != null) return s;
        if (Colors.isHex(color)) {
            String hex = normalizeHex(color);
            return new Swatch(mix(hex, background, 0.86), hex, text);
        }
        return neutral;
    }

    /** Tinted background for a colored group. */
    public String groupFill(String color) {
        if (color == null) return groupFill;
        Swatch s = palette.get(color);
        String base = s != null ? s.stroke() : Colors.isHex(color) ? normalizeHex(color) : null;
        return base == null ? groupFill : mix(base, background, name.equals("dark") ? 0.86 : 0.93);
    }

    public String groupStroke(String color) {
        if (color == null) return groupStroke;
        Swatch s = palette.get(color);
        String base = s != null ? s.stroke() : Colors.isHex(color) ? normalizeHex(color) : null;
        return base == null ? groupStroke : mix(base, background, 0.45);
    }

    public String groupText(String color) {
        if (color == null) return groupText;
        Swatch s = palette.get(color);
        return s != null ? s.text() : groupText;
    }

    static String normalizeHex(String c) {
        String h = c.startsWith("#") ? c.substring(1) : c;
        if (h.length() == 3) h = "" + h.charAt(0) + h.charAt(0) + h.charAt(1) + h.charAt(1) + h.charAt(2) + h.charAt(2);
        return "#" + h.toLowerCase(Locale.ROOT);
    }

    /** {@code t} of the way from {@code a} toward {@code b}. */
    static String mix(String a, String b, double t) {
        int[] x = rgb(a), y = rgb(b);
        return String.format("#%02x%02x%02x", (int) Math.round(x[0] + (y[0] - x[0]) * t),
                (int) Math.round(x[1] + (y[1] - x[1]) * t), (int) Math.round(x[2] + (y[2] - x[2]) * t));
    }

    public static int[] rgb(String hex) {
        String h = normalizeHex(hex).substring(1);
        return new int[]{Integer.parseInt(h.substring(0, 2), 16), Integer.parseInt(h.substring(2, 4), 16),
                Integer.parseInt(h.substring(4, 6), 16)};
    }
}
