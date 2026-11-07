package dev.flowforge.model;

import java.util.List;
import java.util.Objects;

/**
 * A group of nodes drawn on a shared background. A {@code lane} is a swimlane: its members are kept
 * in one band that spans the whole diagram.
 */
public record Group(String id, String label, String color, boolean lane, List<String> members) {
    public Group {
        Objects.requireNonNull(id, "id");
        if (label == null) label = id;
        members = List.copyOf(members == null ? List.of() : members);
    }
}
