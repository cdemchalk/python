package dev.flowforge.layout;

import dev.flowforge.model.NodeType;

/** Node outlines in node-local coordinates (centered on 0,0). */
public final class Shapes {
    private static final double K = 0.5523; // cubic approximation of a quarter circle

    private Shapes() {}

    /** Outline (filled and stroked) and optional decoration (stroked only). */
    public record Shape(PathData outline, PathData decor, double textDy) {}

    public static Shape of(NodeType type, double w, double h) {
        double a = w / 2, b = h / 2;
        return switch (type) {
            case START, END -> new Shape(roundRect(a, b, b), null, 0);
            case STEP -> new Shape(roundRect(a, b, 8), null, 0);
            case DECIDE -> new Shape(PathData.builder().m(0, -b).l(a, 0).l(0, b).l(-a, 0).z().build(), null, 0);
            case DB -> {
                double ry = cylinderRy(h);
                double top = -b + ry, bot = b - ry;
                PathData out = PathData.builder()
                        .m(-a, top)
                        .c(-a, top - K * ry, -K * a, -b, 0, -b)
                        .c(K * a, -b, a, top - K * ry, a, top)
                        .l(a, bot)
                        .c(a, bot + K * ry, K * a, b, 0, b)
                        .c(-K * a, b, -a, bot + K * ry, -a, bot)
                        .z().build();
                PathData decor = PathData.builder()
                        .m(-a, top)
                        .c(-a, top + K * ry, -K * a, top + ry, 0, top + ry)
                        .c(K * a, top + ry, a, top + K * ry, a, top)
                        .build();
                yield new Shape(out, decor, ry * 0.7);
            }
            case DOC -> {
                double r = 6, wave = 7, base = b - wave;
                PathData out = PathData.builder()
                        .m(-a + r, -b)
                        .l(a - r, -b)
                        .c(a - r + K * r, -b, a, -b + r - K * r, a, -b + r)
                        .l(a, base)
                        .c(a * 0.45, base - 2 * wave, -a * 0.45, base + 2.4 * wave, -a, base)
                        .l(-a, -b + r)
                        .c(-a, -b + r - K * r, -a + r - K * r, -b, -a + r, -b)
                        .z().build();
                yield new Shape(out, null, -wave / 2);
            }
            case NOTE -> {
                double f = 12;
                PathData out = PathData.builder().m(-a, -b).l(a - f, -b).l(a, -b + f).l(a, b).l(-a, b).z().build();
                PathData decor = PathData.builder().m(a - f, -b).l(a - f, -b + f).l(a, -b + f).build();
                yield new Shape(out, decor, 0);
            }
        };
    }

    static double cylinderRy(double h) { return Math.min(9, h * 0.14); }

    public static PathData roundRect(double a, double b, double r) {
        r = Math.min(r, Math.min(a, b));
        double k = K * r;
        return PathData.builder()
                .m(-a + r, -b)
                .l(a - r, -b).c(a - r + k, -b, a, -b + r - k, a, -b + r)
                .l(a, b - r).c(a, b - r + k, a - r + k, b, a - r, b)
                .l(-a + r, b).c(-a + r - k, b, -a, b - r + k, -a, b - r)
                .l(-a, -b + r).c(-a, -b + r - k, -a + r - k, -b, -a + r, -b)
                .z().build();
    }

    /** Natural size of a node for a label. */
    public static double[] size(NodeType type, String label) {
        String[] lines = TextMetrics.lines(label);
        double tw = TextMetrics.maxLineWidth(label, 14);
        double th = lines.length * 18;
        return switch (type) {
            case START, END -> new double[]{Math.max(110, tw + 44), Math.max(44, th + 24)};
            case STEP -> new double[]{Math.max(120, tw + 36), Math.max(46, th + 26)};
            case DECIDE -> {
                double a = tw / 2 + th * 0.9 + 14;
                double bb = th / 2 + tw * 0.18 + 14;
                yield new double[]{Math.max(120, 2 * a), Math.max(64, 2 * bb)};
            }
            case DB -> new double[]{Math.max(110, tw + 40), Math.max(64, th + 42)};
            case DOC -> new double[]{Math.max(110, tw + 36), Math.max(54, th + 34)};
            case NOTE -> new double[]{Math.max(90, tw + 32), Math.max(40, th + 22)};
        };
    }
}
