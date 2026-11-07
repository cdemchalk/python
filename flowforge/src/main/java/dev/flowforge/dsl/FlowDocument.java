package dev.flowforge.dsl;

import dev.flowforge.model.Diagram;
import dev.flowforge.model.Direction;
import dev.flowforge.model.Edge;
import dev.flowforge.model.Group;
import dev.flowforge.model.Node;
import dev.flowforge.model.NodeType;
import dev.flowforge.model.Point;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * A parsed .flow file: an ordered list of statements with their original text. This is the source of
 * truth that edit operations change; {@link #toDiagram()} derives the immutable model from it.
 */
public final class FlowDocument {
    private final List<Entry> entries;
    private final String lineSeparator;
    private final boolean trailingNewline;

    public FlowDocument(List<Entry> entries, String lineSeparator, boolean trailingNewline) {
        this.entries = List.copyOf(entries);
        this.lineSeparator = lineSeparator == null ? "\n" : lineSeparator;
        this.trailingNewline = trailingNewline;
    }

    public List<Entry> entries() { return entries; }

    public String lineSeparator() { return lineSeparator; }

    public boolean trailingNewline() { return trailingNewline; }

    public FlowDocument withEntries(List<Entry> e) { return new FlowDocument(e, lineSeparator, trailingNewline); }

    /** Location of each diagram edge: the entry index and the arrow position inside its chain. */
    public record EdgeRef(int entryIndex, int arrowIndex) {}

    public List<EdgeRef> edgeRefs() {
        List<EdgeRef> refs = new ArrayList<>();
        for (int i = 0; i < entries.size(); i++)
            if (entries.get(i).stmt() instanceof Stmt.EdgeChain ch)
                for (int a = 0; a < ch.arrows().size(); a++) refs.add(new EdgeRef(i, a));
        return refs;
    }

    /** First source line mentioning node {@code id} (its declaration if any), or 0. */
    public int lineOf(String id) {
        int ref = 0;
        for (Entry e : entries) {
            if (e.stmt() instanceof Stmt.NodeDecl d && d.id().equals(id)) return e.line();
            if (ref == 0 && e.stmt() instanceof Stmt.EdgeChain ch && ch.nodes().contains(id)) ref = e.line();
        }
        return ref;
    }

    /** Resolves references and builds the model. Throws {@link FlowParseException} on semantic errors. */
    public Diagram toDiagram() {
        List<ParseError> errors = new ArrayList<>();
        String title = null, theme = null;
        Direction direction = Direction.TB;
        Map<String, Node> nodes = new LinkedHashMap<>();
        Map<String, Integer> declaredAt = new HashMap<>();
        List<Edge> edges = new ArrayList<>();
        List<Group> groups = new ArrayList<>();
        Map<String, Point> positions = new LinkedHashMap<>();

        for (Entry e : entries) {
            switch (e.stmt()) {
                case Stmt.Title t -> title = t.text();
                case Stmt.DirectionStmt d -> direction = d.direction();
                case Stmt.ThemeStmt t -> theme = t.theme();
                case Stmt.NodeDecl d -> {
                    Integer prev = declaredAt.putIfAbsent(d.id(), e.line());
                    if (prev != null) {
                        errors.add(error(e, d.id(), "duplicate node id '" + d.id() + "' (first declared on line "
                                + prev + ")" + (d.type().keywordIsDefaultId() && d.id().equals(d.type().keyword())
                                ? "; give it an explicit id, e.g. " + d.type().keyword() + " " + d.type().keyword()
                                + "2 \"...\"" : "")));
                    } else {
                        nodes.put(d.id(), new Node(d.id(), d.type(), defaultLabel(d), d.color(), false));
                    }
                }
                case Stmt.EdgeChain ch -> {
                    for (String id : ch.nodes())
                        nodes.putIfAbsent(id, new Node(id, NodeType.STEP, id, null, true));
                    for (int i = 0; i < ch.arrows().size(); i++)
                        edges.add(new Edge(ch.nodes().get(i), ch.nodes().get(i + 1), ch.label(), ch.arrows().get(i)));
                }
                default -> { }
            }
        }
        Set<String> groupIds = new HashSet<>();
        Map<String, String> laneOf = new HashMap<>();
        for (Entry e : entries) {
            if (e.stmt() instanceof Stmt.GroupDecl g) {
                if (!groupIds.add(g.id()))
                    errors.add(error(e, g.id(), "duplicate group id '" + g.id() + "'"));
                for (String m : g.members()) {
                    if (!nodes.containsKey(m)) {
                        errors.add(error(e, m, "unknown node '" + m + "' in " + (g.lane() ? "lane" : "group")
                                + " '" + g.label() + "'; declare it or connect it with an edge first"));
                    } else if (g.lane()) {
                        String prev = laneOf.putIfAbsent(m, g.id());
                        if (prev != null && !prev.equals(g.id()))
                            errors.add(error(e, m, "node '" + m + "' is already in lane '" + prev
                                    + "'; a node can be in only one lane"));
                    }
                }
                groups.add(new Group(g.id(), g.label() == null ? g.id() : g.label(), g.color(), g.lane(),
                        g.members().stream().distinct().toList()));
            } else if (e.stmt() instanceof Stmt.PosDecl p && nodes.containsKey(p.id())) {
                positions.put(p.id(), new Point(p.x(), p.y()));
            }
        }
        if (!errors.isEmpty()) throw new FlowParseException(errors);
        return new Diagram(title, direction, theme, new ArrayList<>(nodes.values()), edges, groups, positions);
    }

    static String defaultLabel(Stmt.NodeDecl d) {
        if (d.label() != null) return d.label();
        if (d.type().keywordIsDefaultId() && d.id().equals(d.type().keyword()))
            return Character.toUpperCase(d.id().charAt(0)) + d.id().substring(1);
        return d.id();
    }

    private static ParseError error(Entry e, String token, String msg) {
        String raw = e.raw() == null ? "" : e.raw();
        String[] lines = raw.split("\n", -1);
        for (int i = 0; i < lines.length; i++) {
            int col = findWord(lines[i], token);
            if (col >= 0) return new ParseError(e.line() + i, col + 1, msg, lines[i]);
        }
        return new ParseError(e.line(), 1, msg, lines.length > 0 ? lines[0] : "");
    }

    private static int findWord(String line, String w) {
        int from = 0;
        while (true) {
            int i = line.indexOf(w, from);
            if (i < 0) return -1;
            boolean okL = i == 0 || !Ids.isIdChar(line.charAt(i - 1));
            boolean okR = i + w.length() >= line.length() || !Ids.isIdChar(line.charAt(i + w.length()));
            if (okL && okR) return i;
            from = i + 1;
        }
    }
}
