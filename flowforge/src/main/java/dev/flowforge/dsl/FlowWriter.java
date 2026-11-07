package dev.flowforge.dsl;

import dev.flowforge.model.Diagram;
import dev.flowforge.model.Edge;
import dev.flowforge.model.Group;
import dev.flowforge.model.Node;
import dev.flowforge.model.Point;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;

/** Writes documents back to text: untouched statements verbatim, edited ones regenerated. */
public final class FlowWriter {
    private FlowWriter() {}

    public static String write(FlowDocument doc) {
        StringBuilder sb = new StringBuilder();
        List<Entry> es = doc.entries();
        for (int i = 0; i < es.size(); i++) {
            Entry e = es.get(i);
            String text = e.raw() != null ? e.raw() : regenerate(e);
            sb.append(text.replace("\n", doc.lineSeparator()));
            if (i < es.size() - 1 || doc.trailingNewline()) sb.append(doc.lineSeparator());
        }
        return sb.toString();
    }

    static String regenerate(Entry e) {
        String body = render(e.stmt(), e.indent());
        String first = e.indent() + body;
        if (e.trailingComment() != null) {
            int nl = first.indexOf('\n');
            first = nl < 0 ? first + "  " + e.trailingComment()
                    : first.substring(0, nl) + "  " + e.trailingComment() + first.substring(nl);
        }
        return first;
    }

    /** Canonical text for one statement (without indent). */
    public static String render(Stmt s) { return render(s, ""); }

    static String render(Stmt s, String indent) {
        return switch (s) {
            case Stmt.Blank b -> "";
            case Stmt.Comment c -> c.text();
            case Stmt.Title t -> "title " + text(t.text());
            case Stmt.DirectionStmt d -> "direction " + d.direction().name();
            case Stmt.ThemeStmt t -> "theme " + t.theme();
            case Stmt.NodeDecl d -> {
                StringBuilder sb = new StringBuilder(d.type().keyword());
                boolean defaultId = d.type().keywordIsDefaultId() && d.id().equals(d.type().keyword());
                if (!defaultId) sb.append(' ').append(d.id());
                if (d.label() != null && !(d.label().equals(d.id()) && !defaultId))
                    sb.append(' ').append(quote(d.label()));
                if (d.color() != null) sb.append(" #").append(d.color());
                yield sb.toString();
            }
            case Stmt.EdgeChain ch -> {
                StringBuilder sb = new StringBuilder(ch.nodes().get(0));
                for (int i = 0; i < ch.arrows().size(); i++)
                    sb.append(' ').append(ch.arrows().get(i).arrow()).append(' ').append(ch.nodes().get(i + 1));
                if (ch.label() != null) sb.append(" : ").append(text(ch.label()));
                yield sb.toString();
            }
            case Stmt.GroupDecl g -> {
                StringBuilder sb = new StringBuilder(g.lane() ? "lane" : "group");
                boolean derived = g.label() != null && Ids.slug(g.label()).equals(g.id());
                if (!derived) sb.append(' ').append(g.id());
                if (g.label() != null) sb.append(' ').append(quote(g.label()));
                if (g.color() != null) sb.append(" #").append(g.color());
                if (g.multiline()) {
                    sb.append(" {");
                    for (String m : g.members()) sb.append('\n').append(indent).append("  ").append(m);
                    sb.append('\n').append(indent).append('}');
                } else {
                    sb.append(" { ").append(String.join(", ", g.members())).append(g.members().isEmpty() ? "}" : " }");
                }
                yield sb.toString();
            }
            case Stmt.PosDecl p -> "@pos " + p.id() + " " + num(p.x()) + "," + num(p.y());
        };
    }

    /** Free text (title, edge label): bare when unambiguous, quoted otherwise. */
    static String text(String t) {
        boolean bare = !t.isEmpty() && t.equals(t.strip()) && !t.contains("#!") && !t.contains("\n")
                && !t.startsWith("\"");
        return bare ? t : quote(t);
    }

    public static String quote(String s) {
        return '"' + s.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n") + '"';
    }

    static String num(double v) {
        if (v == Math.rint(v) && Math.abs(v) < 1e9) return Long.toString((long) v);
        return String.format(java.util.Locale.ROOT, "%.1f", v);
    }

    /** Builds a fresh canonical document from a model (used by import-json). */
    public static FlowDocument fromDiagram(Diagram d) {
        List<Entry> es = new ArrayList<>();
        if (d.title() != null) es.add(Entry.of(new Stmt.Title(d.title())));
        es.add(Entry.of(new Stmt.DirectionStmt(d.direction())));
        if (d.theme() != null) es.add(Entry.of(new Stmt.ThemeStmt(d.theme())));
        es.add(Entry.of(new Stmt.Blank()));
        boolean any = false;
        for (Node n : d.nodes()) {
            if (n.implicit()) continue;
            String label = n.label();
            if (n.type().keywordIsDefaultId() && n.id().equals(n.type().keyword())
                    && label.equals(FlowDocument.defaultLabel(new Stmt.NodeDecl(n.type(), n.id(), null, null))))
                label = null;
            es.add(Entry.of(new Stmt.NodeDecl(n.type(), n.id(), label, n.color())));
            any = true;
        }
        if (any) es.add(Entry.of(new Stmt.Blank()));
        for (Edge e : d.edges()) es.add(Entry.of(Stmt.EdgeChain.single(e.from(), e.to(), e.style(), e.label())));
        if (!d.groups().isEmpty()) {
            es.add(Entry.of(new Stmt.Blank()));
            for (Group g : d.groups())
                es.add(Entry.of(new Stmt.GroupDecl(g.id(), g.label(), g.color(), g.lane(), g.members(), false)));
        }
        if (!d.positions().isEmpty()) {
            es.add(Entry.of(new Stmt.Blank()));
            for (Map.Entry<String, Point> p : d.positions().entrySet())
                es.add(Entry.of(new Stmt.PosDecl(p.getKey(), p.getValue().x(), p.getValue().y())));
        }
        while (!es.isEmpty() && es.get(es.size() - 1).stmt() instanceof Stmt.Blank) es.remove(es.size() - 1);
        return new FlowDocument(es, "\n", true);
    }
}
