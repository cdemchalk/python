package dev.flowforge.model;

import java.util.Objects;

/**
 * A diagram node.
 *
 * @param color    palette name (e.g. "blue") or hex ("#3366ff"/"3366ff"); null for the theme default
 * @param implicit true when the node is only referenced by edges and never declared
 */
public record Node(String id, NodeType type, String label, String color, boolean implicit) {
    public Node {
        Objects.requireNonNull(id, "id");
        Objects.requireNonNull(type, "type");
        if (label == null) label = id;
    }

    public Node withLabel(String newLabel) { return new Node(id, type, newLabel, color, implicit); }
}
