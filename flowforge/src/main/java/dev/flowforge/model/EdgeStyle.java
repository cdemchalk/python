package dev.flowforge.model;

import com.fasterxml.jackson.annotation.JsonCreator;
import com.fasterxml.jackson.annotation.JsonValue;

/** Edge line styles and their DSL arrows. */
public enum EdgeStyle {
    SOLID("solid", "->"),
    DASHED("dashed", "-.->"),
    THICK("thick", "==>");

    private final String name;
    private final String arrow;

    EdgeStyle(String name, String arrow) { this.name = name; this.arrow = arrow; }

    public String arrow() { return arrow; }

    @JsonValue
    public String jsonName() { return name; }

    @JsonCreator
    public static EdgeStyle parse(String s) {
        for (EdgeStyle e : values()) if (e.name.equals(s) || e.arrow.equals(s)) return e;
        throw new IllegalArgumentException("unknown edge style '" + s + "'");
    }
}
