package dev.flowforge.render;

import dev.flowforge.layout.LayoutEngine;
import dev.flowforge.layout.LayoutResult;
import dev.flowforge.layout.LayoutResult.EdgeRoute;
import dev.flowforge.layout.LayoutResult.GroupBox;
import dev.flowforge.layout.LayoutResult.NodeBox;
import dev.flowforge.layout.Shapes;
import dev.flowforge.layout.TextMetrics;
import dev.flowforge.model.EdgeStyle;
import dev.flowforge.model.NodeType;

import java.util.Locale;

/**
 * Renders a layout to a standalone SVG. Styling uses presentation attributes (no CSS needed), so the file looks
 * the same in browsers, editors and image viewers. Elements carry {@code data-*} attributes and classes that the
 * live preview uses for editing.
 */
public final class SvgRenderer {
    public static final String FONT = "Inter, ui-sans-serif, -apple-system, 'Segoe UI', Helvetica, Arial, sans-serif";

    private SvgRenderer() {}

    public static String render(LayoutResult r, Theme t) {
        var b = r.bounds();
        StringBuilder s = new StringBuilder(8192);
        s.append("<svg xmlns=\"http://www.w3.org/2000/svg\" class=\"ff-diagram\" data-theme=\"").append(t.name())
                .append("\" viewBox=\"").append(n(b.x())).append(' ').append(n(b.y())).append(' ').append(n(b.w()))
                .append(' ').append(n(b.h())).append("\" width=\"").append(n(b.w())).append("\" height=\"")
                .append(n(b.h())).append("\" font-family=\"").append(FONT).append("\">\n");
        if (r.title() != null) s.append("<title>").append(esc(r.title())).append("</title>\n");
        s.append("<defs>\n")
                .append("<marker id=\"ff-arrow\" viewBox=\"0 0 10 10\" refX=\"9\" refY=\"5\" markerWidth=\"10\" ")
                .append("markerHeight=\"10\" markerUnits=\"userSpaceOnUse\" orient=\"auto\">")
                .append("<path d=\"M0.5,1.2 L9.5,5 L0.5,8.8 Q2.2,5 0.5,1.2 Z\" fill=\"").append(t.edge()).append("\"/></marker>\n")
                .append("<filter id=\"ff-shadow\" x=\"-20%\" y=\"-20%\" width=\"140%\" height=\"150%\">")
                .append("<feDropShadow dx=\"0\" dy=\"1.5\" stdDeviation=\"2\" flood-color=\"#000\" flood-opacity=\"")
                .append(n(t.shadowOpacity())).append("\"/></filter>\n")
                .append("</defs>\n");
        s.append("<rect class=\"ff-bg\" x=\"").append(n(b.x())).append("\" y=\"").append(n(b.y()))
                .append("\" width=\"").append(n(b.w())).append("\" height=\"").append(n(b.h()))
                .append("\" fill=\"").append(t.background()).append("\"/>\n");

        s.append("<g class=\"ff-groups\">\n");
        for (GroupBox g : r.groups()) if (g.lane()) lane(s, g, t);
        for (GroupBox g : r.groups()) if (!g.lane()) group(s, g, t);
        s.append("</g>\n");

        if (r.titlePos() != null) {
            s.append("<text class=\"ff-title\" x=\"").append(n(r.titlePos().x())).append("\" y=\"")
                    .append(n(r.titlePos().y())).append("\" font-size=\"18\" font-weight=\"650\" fill=\"")
                    .append(t.title()).append("\">").append(esc(r.title())).append("</text>\n");
        }

        s.append("<g class=\"ff-edges\" fill=\"none\">\n");
        for (EdgeRoute e : r.edges()) edge(s, e, t);
        s.append("</g>\n");

        s.append("<g class=\"ff-nodes\">\n");
        for (NodeBox nb : r.nodes()) node(s, nb, t);
        s.append("</g>\n");

        s.append("<g class=\"ff-labels\">\n");
        for (EdgeRoute e : r.edges()) if (e.label() != null) edgeLabel(s, e, t);
        s.append("</g>\n");
        s.append("</svg>\n");
        return s.toString();
    }

    private static void lane(StringBuilder s, GroupBox g, Theme t) {
        String fill = g.color() != null ? t.groupFill(g.color()) : (g.laneIndex() % 2 == 0 ? t.laneFillA() : t.laneFillB());
        s.append("<g class=\"ff-lane\" data-id=\"").append(esc(g.id())).append("\">")
                .append("<rect x=\"").append(n(g.x())).append("\" y=\"").append(n(g.y())).append("\" width=\"")
                .append(n(g.w())).append("\" height=\"").append(n(g.h())).append("\" fill=\"").append(fill)
                .append("\" stroke=\"").append(t.laneStroke()).append("\"/>");
        String color = g.color() != null ? t.groupText(g.color()) : t.laneHeader();
        if (g.labelVertical()) {
            s.append("<text x=\"").append(n(g.labelX())).append("\" y=\"").append(n(g.labelY()))
                    .append("\" transform=\"rotate(-90 ").append(n(g.labelX())).append(' ').append(n(g.labelY()))
                    .append(")\"");
        } else {
            s.append("<text x=\"").append(n(g.labelX())).append("\" y=\"").append(n(g.labelY() + 5)).append('"');
        }
        s.append(" text-anchor=\"middle\" font-size=\"13\" font-weight=\"600\" letter-spacing=\"0.3\" fill=\"")
                .append(color).append("\">").append(esc(g.label())).append("</text></g>\n");
    }

    private static void group(StringBuilder s, GroupBox g, Theme t) {
        s.append("<g class=\"ff-group\" data-id=\"").append(esc(g.id())).append("\">")
                .append("<rect x=\"").append(n(g.x())).append("\" y=\"").append(n(g.y())).append("\" width=\"")
                .append(n(g.w())).append("\" height=\"").append(n(g.h())).append("\" rx=\"12\" fill=\"")
                .append(t.groupFill(g.color())).append("\" stroke=\"").append(t.groupStroke(g.color()))
                .append("\" stroke-dasharray=\"5 4\"/>")
                .append("<text x=\"").append(n(g.labelX())).append("\" y=\"").append(n(g.labelY() + 4))
                .append("\" font-size=\"12\" font-weight=\"600\" letter-spacing=\"0.3\" fill=\"")
                .append(t.groupText(g.color())).append("\">").append(esc(g.label())).append("</text></g>\n");
    }

    private static void edge(StringBuilder s, EdgeRoute e, Theme t) {
        String d = e.path().toSvg();
        s.append("<g class=\"ff-edge\" data-index=\"").append(e.index()).append("\" data-from=\"").append(esc(e.from()))
                .append("\" data-to=\"").append(esc(e.to())).append("\">")
                .append("<path class=\"ff-edge-hit\" d=\"").append(d)
                .append("\" stroke=\"transparent\" stroke-width=\"14\"/>")
                .append("<path class=\"ff-edge-line\" d=\"").append(d).append("\" stroke=\"").append(t.edge())
                .append("\" stroke-width=\"").append(e.style() == EdgeStyle.THICK ? "3" : "1.6").append('"');
        if (e.style() == EdgeStyle.DASHED) s.append(" stroke-dasharray=\"6 5\"");
        s.append(" stroke-linecap=\"round\" marker-end=\"url(#ff-arrow)\"/></g>\n");
    }

    private static void node(StringBuilder s, NodeBox nb, Theme t) {
        Theme.Swatch sw = t.swatch(nb.color(), nb.type());
        Shapes.Shape shape = Shapes.of(nb.type(), nb.w(), nb.h());
        s.append("<g class=\"ff-node ff-").append(nb.type().keyword()).append(nb.pinned() ? " ff-pinned" : "")
                .append("\" data-id=\"").append(esc(nb.id())).append("\" data-x=\"").append(n(nb.x()))
                .append("\" data-y=\"").append(n(nb.y())).append("\" data-w=\"").append(n(nb.w()))
                .append("\" data-h=\"").append(n(nb.h())).append("\" transform=\"translate(").append(n(nb.x()))
                .append(' ').append(n(nb.y())).append(")\">");
        s.append("<path class=\"ff-shape\" d=\"").append(shape.outline().toSvg()).append("\" fill=\"").append(sw.fill())
                .append("\" stroke=\"").append(sw.stroke()).append("\" stroke-width=\"1.6\" filter=\"url(#ff-shadow)\"/>");
        if (shape.decor() != null)
            s.append("<path d=\"").append(shape.decor().toSvg()).append("\" fill=\"none\" stroke=\"")
                    .append(sw.stroke()).append("\" stroke-width=\"1.6\"/>");
        text(s, nb.label(), 0, shape.textDy(), 14, sw.text(), nb.type() == NodeType.NOTE ? "400" : "500");
        s.append("</g>\n");
    }

    private static void edgeLabel(StringBuilder s, EdgeRoute e, Theme t) {
        double w = e.labelW(), h = e.labelH();
        s.append("<g class=\"ff-edge-label\" data-index=\"").append(e.index()).append("\" transform=\"translate(")
                .append(n(e.labelPos().x())).append(' ').append(n(e.labelPos().y())).append(")\">")
                .append("<rect x=\"").append(n(-w / 2)).append("\" y=\"").append(n(-h / 2)).append("\" width=\"")
                .append(n(w)).append("\" height=\"").append(n(h)).append("\" rx=\"").append(n(Math.min(h / 2, 11)))
                .append("\" fill=\"").append(t.labelBg()).append("\" stroke=\"").append(t.labelBorder()).append("\"/>");
        text(s, e.label(), 0, 0, 12, t.labelText(), "500");
        s.append("</g>\n");
    }

    /** Multi-line text centered on (x, y). */
    private static void text(StringBuilder s, String label, double x, double y, double size, String color,
                             String weight) {
        String[] lines = TextMetrics.lines(label);
        double lh = size * 1.28;
        double first = y - (lines.length - 1) * lh / 2 + size * 0.35;
        s.append("<text text-anchor=\"middle\" font-size=\"").append(n(size)).append("\" font-weight=\"")
                .append(weight).append("\" fill=\"").append(color).append("\">");
        for (int i = 0; i < lines.length; i++) {
            s.append("<tspan x=\"").append(n(x)).append("\" y=\"").append(n(first + i * lh)).append("\">")
                    .append(esc(lines[i])).append("</tspan>");
        }
        s.append("</text>");
    }

    static String n(double v) {
        double r = Math.round(v * 10) / 10.0;
        if (r == Math.rint(r)) return Long.toString((long) r);
        return String.format(Locale.ROOT, "%.1f", r);
    }

    static String esc(String s) {
        StringBuilder b = new StringBuilder(s.length());
        for (char c : s.toCharArray()) {
            switch (c) {
                case '<' -> b.append("&lt;");
                case '>' -> b.append("&gt;");
                case '&' -> b.append("&amp;");
                case '"' -> b.append("&quot;");
                default -> b.append(c);
            }
        }
        return b.toString();
    }

    /** Convenience: layout + render. */
    public static String render(dev.flowforge.model.Diagram d, Theme t) {
        return render(new LayoutEngine().layout(d), t);
    }
}
