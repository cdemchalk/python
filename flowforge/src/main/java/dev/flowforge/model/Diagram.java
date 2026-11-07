package dev.flowforge.model;

import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;

/** Immutable diagram model. {@code positions} holds manual node centers set with {@code @pos}. */
public record Diagram(String title, Direction direction, String theme,
                      List<Node> nodes, List<Edge> edges, List<Group> groups,
                      Map<String, Point> positions) {
    public Diagram {
        if (direction == null) direction = Direction.TB;
        nodes = List.copyOf(nodes == null ? List.of() : nodes);
        edges = List.copyOf(edges == null ? List.of() : edges);
        groups = List.copyOf(groups == null ? List.of() : groups);
        positions = Collections.unmodifiableMap(new LinkedHashMap<>(positions == null ? Map.of() : positions));
    }

    public Optional<Node> node(String id) {
        return nodes.stream().filter(n -> n.id().equals(id)).findFirst();
    }

    public boolean hasNode(String id) { return node(id).isPresent(); }
}
