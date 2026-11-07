package dev.flowforge.layout;

import dev.flowforge.model.Direction;
import dev.flowforge.model.EdgeStyle;
import dev.flowforge.model.NodeType;
import dev.flowforge.model.Point;

import java.util.List;

/** Positioned diagram ready for rendering. All coordinates are absolute SVG user units. */
public record LayoutResult(String title, Direction direction, List<NodeBox> nodes, List<EdgeRoute> edges,
                           List<GroupBox> groups, Bounds bounds, Point titlePos) {

    /** {@code x,y} is the node center. */
    public record NodeBox(String id, NodeType type, String label, String color, double x, double y, double w,
                          double h, int rank, boolean pinned) {
        public double left() { return x - w / 2; }

        public double right() { return x + w / 2; }

        public double top() { return y - h / 2; }

        public double bottom() { return y + h / 2; }
    }

    /** {@code labelPos} is the center of the label chip (null without label). */
    public record EdgeRoute(int index, String from, String to, String label, EdgeStyle style, PathData path,
                            Point labelPos, double labelW, double labelH) {}

    /** For lanes in LR layouts the label is drawn rotated in a header column. */
    public record GroupBox(String id, String label, String color, boolean lane, double x, double y, double w,
                           double h, double labelX, double labelY, boolean labelVertical, int laneIndex) {}

    public record Bounds(double x, double y, double w, double h) {}
}
