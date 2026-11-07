package dev.flowforge.model;

import java.util.Objects;

/** A directed edge. {@code label} may be null. */
public record Edge(String from, String to, String label, EdgeStyle style) {
    public Edge {
        Objects.requireNonNull(from, "from");
        Objects.requireNonNull(to, "to");
        if (style == null) style = EdgeStyle.SOLID;
    }
}
