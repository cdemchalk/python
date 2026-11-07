package dev.flowforge.layout;

import dev.flowforge.dsl.FlowParser;
import dev.flowforge.layout.LayoutResult.GroupBox;
import dev.flowforge.layout.LayoutResult.NodeBox;
import dev.flowforge.model.Diagram;
import dev.flowforge.model.Direction;
import dev.flowforge.model.Edge;
import dev.flowforge.model.Node;
import dev.flowforge.model.NodeType;
import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Random;
import java.util.function.Function;
import java.util.stream.Collectors;

import static org.junit.jupiter.api.Assertions.*;

class LayoutEngineTest {
    static LayoutResult layout(String text) { return new LayoutEngine().layout(FlowParser.parse(text).toDiagram()); }

    static Map<String, NodeBox> byId(LayoutResult r) {
        return r.nodes().stream().collect(Collectors.toMap(NodeBox::id, Function.identity()));
    }

    static void assertNoOverlap(LayoutResult r, String ctx) {
        List<NodeBox> ns = r.nodes();
        for (int i = 0; i < ns.size(); i++)
            for (int j = i + 1; j < ns.size(); j++) {
                NodeBox a = ns.get(i), b = ns.get(j);
                boolean overlap = a.left() < b.right() && b.left() < a.right() && a.top() < b.bottom()
                        && b.top() < a.bottom();
                assertFalse(overlap, ctx + ": " + a.id() + " overlaps " + b.id());
            }
    }

    static List<String> examples() throws IOException {
        try (var s = Files.list(Path.of("examples"))) {
            return s.filter(p -> p.toString().endsWith(".flow")).sorted().map(p -> {
                try {
                    return Files.readString(p);
                } catch (IOException e) {
                    throw new RuntimeException(e);
                }
            }).toList();
        }
    }

    @Test
    void examplesHaveNoOverlapsAndGroupsHoldOnlyMembers() throws IOException {
        for (String text : examples()) {
            Diagram d = FlowParser.parse(text).toDiagram();
            for (Direction dir : Direction.values()) {
                Diagram dd = new Diagram(d.title(), dir, d.theme(), d.nodes(), d.edges(), d.groups(), d.positions());
                LayoutResult r = new LayoutEngine().layout(dd);
                String ctx = d.title() + " " + dir;
                assertNoOverlap(r, ctx);
                for (GroupBox g : r.groups()) {
                    var members = d.groups().stream().filter(x -> x.id().equals(g.id())).findFirst().orElseThrow().members();
                    for (NodeBox n : r.nodes()) {
                        boolean inside = n.left() >= g.x() - 0.5 && n.right() <= g.x() + g.w() + 0.5
                                && n.top() >= g.y() - 0.5 && n.bottom() <= g.y() + g.h() + 0.5;
                        boolean intersects = n.left() < g.x() + g.w() && n.right() > g.x()
                                && n.top() < g.y() + g.h() && n.bottom() > g.y();
                        if (members.contains(n.id())) assertTrue(inside, ctx + ": " + n.id() + " outside " + g.id());
                        else if (!g.lane()) assertFalse(intersects, ctx + ": " + n.id() + " inside group " + g.id());
                    }
                }
            }
        }
    }

    @Test
    void ranksFollowEdgesTopToBottom() {
        LayoutResult r = layout("""
                start -> a -> b -> d
                a -> c -> d
                d -> end
                start -> d
                """);
        var n = byId(r);
        for (var e : List.of(new String[]{"start", "a"}, new String[]{"a", "b"}, new String[]{"b", "d"},
                new String[]{"a", "c"}, new String[]{"c", "d"}, new String[]{"d", "end"}, new String[]{"start", "d"})) {
            NodeBox from = n.get(e[0]), to = n.get(e[1]);
            assertTrue(to.rank() > from.rank(), e[0] + "->" + e[1]);
            assertTrue(to.top() > from.bottom(), e[0] + " above " + e[1]);
        }
        assertEquals(3, n.get("d").rank(), "longest path");
        assertEquals(n.get("b").y(), n.get("c").y(), "same rank, same row");
    }

    @Test
    void leftToRightUsesXForRanks() {
        LayoutResult r = layout("direction LR\na -> b -> c\na -> c");
        var n = byId(r);
        assertTrue(n.get("b").left() > n.get("a").right());
        assertTrue(n.get("c").left() > n.get("b").right());
    }

    @Test
    void bottomToTopAndRightToLeftMirror() {
        var bt = byId(layout("direction BT\na -> b"));
        assertTrue(bt.get("b").bottom() < bt.get("a").top());
        var rl = byId(layout("direction RL\na -> b"));
        assertTrue(rl.get("b").right() < rl.get("a").left());
    }

    @Test
    void cyclesAreBrokenAndEveryEdgeIsRouted() {
        LayoutResult r = layout("a -> b -> c -> a\nc -> c : again\nb -> a");
        assertEquals(5, r.edges().size());
        var n = byId(r);
        assertEquals(0, n.get("a").rank());
        assertEquals(1, n.get("b").rank());
        assertEquals(2, n.get("c").rank());
        assertNoOverlap(r, "cycle");
        r.edges().forEach(e -> assertFalse(e.path().ops().isEmpty()));
        assertNotNull(r.edges().get(3).labelPos(), "self loop label");
    }

    @Test
    void sourcesAreDrawnNextToTheirTarget() {
        var n = byId(layout("a -> b -> c -> d\nnote n \"Hint\"\nn -.-> d"));
        assertEquals(2, n.get("n").rank());
    }

    @Test
    void manualPositionsOverrideOnlyThatNode() {
        LayoutResult free = layout("a -> b -> c\na -> d");
        LayoutResult pinned = layout("a -> b -> c\na -> d\n@pos c 500,-40");
        var f = byId(free);
        var p = byId(pinned);
        assertEquals(500, p.get("c").x());
        assertEquals(-40, p.get("c").y());
        assertTrue(p.get("c").pinned());
        for (String id : List.of("a", "b", "d")) {
            assertEquals(f.get(id).x(), p.get(id).x(), id);
            assertEquals(f.get(id).y(), p.get(id).y(), id);
        }
        assertTrue(pinned.bounds().y() < -40 - 20, "bounds include pinned node");
    }

    @Test
    void lanesAreDisjointBandsHoldingTheirMembers() {
        LayoutResult r = layout("""
                a -> b -> c -> d
                a -> d
                lane x "X" { a, d }
                lane y "Y" { b }
                lane z "Z" { c }
                """);
        var n = byId(r);
        List<GroupBox> lanes = r.groups().stream().filter(GroupBox::lane).toList();
        assertEquals(3, lanes.size());
        for (int i = 0; i + 1 < lanes.size(); i++)
            assertTrue(lanes.get(i).x() + lanes.get(i).w() <= lanes.get(i + 1).x() + 0.01, "lanes in order");
        GroupBox x = lanes.get(0);
        for (String id : List.of("a", "d")) {
            assertTrue(n.get(id).left() > x.x() && n.get(id).right() < x.x() + x.w(), id);
        }
    }

    @Test
    void randomGraphsNeverOverlap() {
        Random rnd = new Random(42);
        NodeType[] types = NodeType.values();
        for (int round = 0; round < 60; round++) {
            int count = 2 + rnd.nextInt(16);
            List<Node> nodes = new ArrayList<>();
            for (int i = 0; i < count; i++)
                nodes.add(new Node("n" + i, types[rnd.nextInt(types.length)], "Node " + "x".repeat(rnd.nextInt(20)) + i,
                        null, false));
            List<Edge> edges = new ArrayList<>();
            int ec = rnd.nextInt(count * 2);
            for (int i = 0; i < ec; i++)
                edges.add(new Edge("n" + rnd.nextInt(count), "n" + rnd.nextInt(count),
                        rnd.nextBoolean() ? null : "l" + i, null));
            List<dev.flowforge.model.Group> groups = new ArrayList<>();
            if (count > 4 && rnd.nextBoolean())
                groups.add(new dev.flowforge.model.Group("g", "G", null, false, List.of("n0", "n1", "n2")));
            Direction dir = rnd.nextBoolean() ? Direction.TB : Direction.LR;
            Diagram d = new Diagram("t", dir, null, nodes, edges, groups, Map.of());
            LayoutResult r = new LayoutEngine().layout(d);
            assertNoOverlap(r, "round " + round);
            assertEquals(edges.size(), r.edges().size());
            for (NodeBox nb : r.nodes()) {
                assertTrue(Double.isFinite(nb.x()) && Double.isFinite(nb.y()), "finite");
                assertTrue(nb.left() >= r.bounds().x() && nb.right() <= r.bounds().x() + r.bounds().w());
            }
        }
    }

    @Test
    void layoutIsDeterministic() throws IOException {
        for (String text : examples())
            assertEquals(dev.flowforge.render.SvgRenderer.render(layout(text), dev.flowforge.render.Theme.light()),
                    dev.flowforge.render.SvgRenderer.render(layout(text), dev.flowforge.render.Theme.light()));
    }

    @Test
    void emptyDiagram() {
        LayoutResult r = layout("title Nothing yet");
        assertTrue(r.nodes().isEmpty());
        assertTrue(r.bounds().w() > 0);
    }

    @Test
    void isotonicRegressionIsMonotoneAndExact() {
        double[] y = invokeIsotonic(new double[]{1, 3, 2, 4}, new double[]{1, 1, 1, 1});
        assertArrayEquals(new double[]{1, 2.5, 2.5, 4}, y, 1e-9);
    }

    static double[] invokeIsotonic(double[] t, double[] w) {
        try {
            Class<?> run = Class.forName("dev.flowforge.layout.LayoutEngine$Run");
            var m = run.getDeclaredMethod("isotonic", double[].class, double[].class);
            m.setAccessible(true);
            return (double[]) m.invoke(null, t, w);
        } catch (ReflectiveOperationException e) {
            throw new RuntimeException(e);
        }
    }
}
