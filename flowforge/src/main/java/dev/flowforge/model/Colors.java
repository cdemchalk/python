package dev.flowforge.model;

import java.util.List;
import java.util.regex.Pattern;

/** Color names accepted by the DSL. Rendering values live in the theme. */
public final class Colors {
    public static final List<String> NAMES =
            List.of("blue", "green", "amber", "red", "purple", "teal", "pink", "orange", "gray");
    private static final Pattern HEX = Pattern.compile("[0-9a-fA-F]{3}|[0-9a-fA-F]{6}");

    private Colors() {}

    public static boolean isValid(String c) {
        return c != null && (NAMES.contains(c) || HEX.matcher(c).matches());
    }

    public static boolean isHex(String c) { return c != null && HEX.matcher(c).matches() && !NAMES.contains(c); }
}
