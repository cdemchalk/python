package dev.flowforge.layout;

import dev.flowforge.model.Point;

import java.util.ArrayList;
import java.util.List;
import java.util.Locale;

/** Minimal path made of move/line/cubic/close commands, shared by the SVG and PNG renderers. */
public record PathData(List<Op> ops) {
    public enum Kind { M, L, C, Z }

    public record Op(Kind kind, double[] p) {}

    public PathData { ops = List.copyOf(ops); }

    public static Builder builder() { return new Builder(); }

    public Point start() { return new Point(ops.get(0).p()[0], ops.get(0).p()[1]); }

    public Point end() {
        double[] p = ops.get(ops.size() - 1).p();
        return new Point(p[p.length - 2], p[p.length - 1]);
    }

    /** All coordinates (endpoints and control points), for bounds. */
    public List<Point> points() {
        List<Point> out = new ArrayList<>();
        for (Op o : ops) for (int i = 0; i + 1 < o.p().length; i += 2) out.add(new Point(o.p()[i], o.p()[i + 1]));
        return out;
    }

    public String toSvg() {
        StringBuilder sb = new StringBuilder();
        for (Op o : ops) {
            if (!sb.isEmpty()) sb.append(' ');
            sb.append(o.kind().name());
            for (int i = 0; i < o.p().length; i += 2) {
                sb.append(i == 0 ? "" : " ").append(f(o.p()[i])).append(',').append(f(o.p()[i + 1]));
            }
        }
        return sb.toString();
    }

    static String f(double v) {
        double r = Math.round(v * 10) / 10.0;
        if (r == Math.rint(r)) return Long.toString((long) r);
        return String.format(Locale.ROOT, "%.1f", r);
    }

    public static final class Builder {
        private final List<Op> ops = new ArrayList<>();

        public Builder m(double x, double y) { ops.add(new Op(Kind.M, new double[]{x, y})); return this; }

        public Builder l(double x, double y) { ops.add(new Op(Kind.L, new double[]{x, y})); return this; }

        public Builder c(double x1, double y1, double x2, double y2, double x, double y) {
            ops.add(new Op(Kind.C, new double[]{x1, y1, x2, y2, x, y}));
            return this;
        }

        public Builder c(Point c1, Point c2, Point p) { return c(c1.x(), c1.y(), c2.x(), c2.y(), p.x(), p.y()); }

        public Builder z() { ops.add(new Op(Kind.Z, new double[0])); return this; }

        public PathData build() { return new PathData(ops); }
    }
}
