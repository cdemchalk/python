package dev.flowforge.dsl;

import java.util.Collection;
import java.util.Locale;
import java.util.regex.Pattern;

/** Identifier rules shared by the parser, the editor and the CLI. */
public final class Ids {
    private static final Pattern ID = Pattern.compile("[A-Za-z0-9_]+");

    private Ids() {}

    public static boolean isValid(String id) { return id != null && ID.matcher(id).matches(); }

    public static boolean isIdChar(char c) { return Character.isLetterOrDigit(c) && c < 128 || c == '_'; }

    /** "Validate account!" -> "validate_account". May return "" for labels without letters or digits. */
    public static String slug(String label) {
        String s = label.toLowerCase(Locale.ROOT).replaceAll("[^a-z0-9]+", "_").replaceAll("^_+|_+$", "");
        return s.length() > 40 ? s.substring(0, 40).replaceAll("_+$", "") : s;
    }

    /** A slug of {@code label} not already in {@code taken}. */
    public static String unique(String label, Collection<String> taken) {
        String base = slug(label);
        if (base.isEmpty()) base = "node";
        String id = base;
        for (int i = 2; taken.contains(id); i++) id = base + "_" + i;
        return id;
    }
}
