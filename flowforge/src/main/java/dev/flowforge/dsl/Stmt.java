package dev.flowforge.dsl;

import dev.flowforge.model.Direction;
import dev.flowforge.model.EdgeStyle;
import dev.flowforge.model.NodeType;

import java.util.List;

/** One statement of a .flow file. Statements are kept in source order so edits preserve layout. */
public sealed interface Stmt {
    record Blank() implements Stmt {}

    /** Whole-line comment; {@code text} includes the leading {@code #!}. */
    record Comment(String text) implements Stmt {}

    record Title(String text) implements Stmt {}

    record DirectionStmt(Direction direction) implements Stmt {}

    record ThemeStmt(String theme) implements Stmt {}

    /** {@code label} and {@code color} may be null. */
    record NodeDecl(NodeType type, String id, String label, String color) implements Stmt {
        public NodeDecl withLabel(String l) { return new NodeDecl(type, id, l, color); }
    }

    /** {@code a -> b -.-> c : label}; {@code arrows.size() == nodes.size() - 1}. */
    record EdgeChain(List<String> nodes, List<EdgeStyle> arrows, String label) implements Stmt {
        public EdgeChain {
            nodes = List.copyOf(nodes);
            arrows = List.copyOf(arrows);
            if (arrows.size() != nodes.size() - 1 || arrows.isEmpty())
                throw new IllegalArgumentException("edge chain needs n nodes and n-1 arrows");
        }

        public static EdgeChain single(String from, String to, EdgeStyle style, String label) {
            return new EdgeChain(List.of(from, to), List.of(style), label);
        }
    }

    record GroupDecl(String id, String label, String color, boolean lane, List<String> members,
                     boolean multiline) implements Stmt {
        public GroupDecl { members = List.copyOf(members); }

        public GroupDecl withMembers(List<String> m) { return new GroupDecl(id, label, color, lane, m, multiline); }
    }

    record PosDecl(String id, double x, double y) implements Stmt {}
}
