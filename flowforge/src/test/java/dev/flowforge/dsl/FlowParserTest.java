package dev.flowforge.dsl;

import dev.flowforge.model.Diagram;
import dev.flowforge.model.Direction;
import dev.flowforge.model.Edge;
import dev.flowforge.model.EdgeStyle;
import dev.flowforge.model.Node;
import dev.flowforge.model.NodeType;
import dev.flowforge.model.Point;
import org.junit.jupiter.api.Test;

import java.util.List;

import static org.junit.jupiter.api.Assertions.*;

class FlowParserTest {
    static final String SPEC = """
            title Loan payment posting
            direction TB
            start  "Payment received"      #blue
            step   validate "Validate account"
            decide active  "Account active?" #amber
            db     ledger  "Loan ledger"    #green
            start -> validate -> active
            active -> apply  : yes
            active -> suspense : no
            group "Core system" { validate, apply, ledger }
            """;

    static Diagram diagram(String text) { return FlowParser.parse(text).toDiagram(); }

    static ParseError firstError(String text) {
        FlowParseException ex = assertThrows(FlowParseException.class, () -> FlowParser.parse(text));
        return ex.errors().get(0);
    }

    @Test
    void parsesSpecExample() {
        Diagram d = diagram(SPEC);
        assertEquals("Loan payment posting", d.title());
        assertEquals(Direction.TB, d.direction());
        assertEquals(List.of("start", "validate", "active", "ledger", "apply", "suspense"),
                d.nodes().stream().map(Node::id).toList());
        Node start = d.node("start").orElseThrow();
        assertEquals(NodeType.START, start.type());
        assertEquals("Payment received", start.label());
        assertEquals("blue", start.color());
        assertEquals(NodeType.DECIDE, d.node("active").orElseThrow().type());
        assertTrue(d.node("apply").orElseThrow().implicit());
        assertEquals("apply", d.node("apply").orElseThrow().label());
        assertEquals(List.of(
                new Edge("start", "validate", null, EdgeStyle.SOLID),
                new Edge("validate", "active", null, EdgeStyle.SOLID),
                new Edge("active", "apply", "yes", EdgeStyle.SOLID),
                new Edge("active", "suspense", "no", EdgeStyle.SOLID)), d.edges());
        assertEquals(1, d.groups().size());
        assertEquals("core_system", d.groups().get(0).id());
        assertEquals(List.of("validate", "apply", "ledger"), d.groups().get(0).members());
    }

    @Test
    void allNodeTypesAndDefaults() {
        Diagram d = diagram("""
                start
                step a
                decide "Is it OK?"
                db store "Store"
                doc report "Report" #ff8800
                note n1 "Remember \\"this\\"\\nsecond line"
                end
                """);
        assertEquals("Start", d.node("start").orElseThrow().label());
        assertEquals("End", d.node("end").orElseThrow().label());
        assertEquals("a", d.node("a").orElseThrow().label());
        assertEquals("is_it_ok", d.nodes().get(2).id());
        assertEquals("ff8800", d.node("report").orElseThrow().color());
        assertEquals("Remember \"this\"\nsecond line", d.node("n1").orElseThrow().label());
        assertEquals(NodeType.NOTE, d.node("n1").orElseThrow().type());
    }

    @Test
    void arrowsChainsAndLabels() {
        Diagram d = diagram("""
                a -> b -.-> c ==> d : maybe later
                c --> a : "quoted #! not a comment"
                """);
        assertEquals(4, d.edges().size());
        assertEquals(EdgeStyle.DASHED, d.edges().get(1).style());
        assertEquals(EdgeStyle.THICK, d.edges().get(2).style());
        assertEquals("maybe later", d.edges().get(0).label());
        assertEquals("quoted #! not a comment", d.edges().get(3).label());
    }

    @Test
    void commentsAreIgnored() {
        Diagram d = diagram("""
                #! a full-line comment
                step a "A" #blue   #! trailing comment
                a -> b #! another
                    #! indented comment
                """);
        assertEquals("blue", d.node("a").orElseThrow().color());
        assertEquals(1, d.edges().size());
        assertNull(d.edges().get(0).label());
    }

    @Test
    void multilineGroupsLanesAndPositions() {
        Diagram d = diagram("""
                direction lr
                a -> b -> c
                lane ops "Operations" #teal {
                  a, b   #! members can be split
                  c
                }
                @pos b 120,240
                @pos c -10.5 7
                """);
        assertEquals(Direction.LR, d.direction());
        var g = d.groups().get(0);
        assertTrue(g.lane());
        assertEquals("ops", g.id());
        assertEquals("teal", g.color());
        assertEquals(List.of("a", "b", "c"), g.members());
        assertEquals(new Point(120, 240), d.positions().get("b"));
        assertEquals(new Point(-10.5, 7), d.positions().get("c"));
    }

    @Test
    void edgeFromKeywordNamedNode() {
        Diagram d = diagram("start \"Go\"\nstart -> x\nx -> end\nend \"Done\"");
        assertEquals(List.of("start", "x", "end"), d.nodes().stream().map(Node::id).toList());
        assertFalse(d.node("end").orElseThrow().implicit());
        assertEquals("Done", d.node("end").orElseThrow().label());
    }

    @Test
    void positionForUnknownNodeIsIgnored() {
        assertTrue(diagram("a -> b\n@pos zzz 1,2").positions().isEmpty());
    }

    // ---------------------------------------------------------------- errors

    @Test
    void unterminatedString() {
        ParseError e = firstError("step a \"Validate\nstep b");
        assertEquals(1, e.line());
        assertEquals(8, e.column());
        assertTrue(e.message().contains("unterminated string"));
    }

    @Test
    void unknownColor() {
        ParseError e = firstError("step a \"A\"\nstep b \"B\" #chartreuse");
        assertEquals(2, e.line());
        assertEquals(12, e.column());
        assertTrue(e.message().contains("unknown color '#chartreuse'"));
    }

    @Test
    void unknownStatement() {
        ParseError e = firstError("stpe validate \"Validate\"");
        assertEquals(1, e.line());
        assertEquals(1, e.column());
        assertTrue(e.message().contains("unknown statement 'stpe'"), e.message());
    }

    @Test
    void missingArrowTarget() {
        ParseError e = firstError("a -> b ->");
        assertEquals(10, e.column());
        assertTrue(e.message().contains("expected a node id after the arrow"));
    }

    @Test
    void badArrow() {
        ParseError e = firstError("a -> b <- c");
        assertEquals(8, e.column());
        assertTrue(e.message().contains("expected '->'"));
    }

    @Test
    void badDirectionAndTheme() {
        assertTrue(firstError("direction up").message().contains("unknown direction 'up'"));
        assertTrue(firstError("theme neon").message().contains("unknown theme"));
    }

    @Test
    void badPos() {
        ParseError e = firstError("a -> b\n@pos a x,1");
        assertEquals(2, e.line());
        assertEquals(8, e.column());
    }

    @Test
    void duplicateIdIsReportedWithBothLines() {
        ParseError e = firstError("step a \"A\"\n\nstep a \"Again\"");
        assertEquals(3, e.line());
        assertEquals(6, e.column());
        assertTrue(e.message().contains("first declared on line 1"));
    }

    @Test
    void duplicateStartSuggestsExplicitId() {
        assertTrue(firstError("start \"A\"\nstart \"B\"").message().contains("explicit id"));
    }

    @Test
    void unknownGroupMember() {
        ParseError e = firstError("a -> b\ngroup \"G\" { a, nope }");
        assertEquals(2, e.line());
        assertEquals(16, e.column());
        assertTrue(e.message().contains("unknown node 'nope'"));
    }

    @Test
    void nodeInTwoLanes() {
        assertTrue(firstError("a -> b\nlane x { a }\nlane y { a, b }").message().contains("only one lane"));
    }

    @Test
    void unclosedGroup() {
        ParseError e = firstError("a -> b\ngroup \"G\" {\n  a\n  b\n");
        assertEquals(2, e.line());
        assertTrue(e.message().contains("unclosed '{'"));
    }

    @Test
    void twoLabelsInDeclaration() {
        assertTrue(firstError("step a \"A\" \"B\"").message().contains("one label"));
    }

    @Test
    void collectsErrorsFromSeveralLines() {
        FlowParseException ex = assertThrows(FlowParseException.class,
                () -> FlowParser.parse("step a \"ok\"\nbogus\nstep b #nope\na -> b\nc ->"));
        assertEquals(List.of(2, 3, 5), ex.errors().stream().map(ParseError::line).toList());
    }

    @Test
    void formatShowsCaret() {
        ParseError e = firstError("step b \"B\" #chartreuse");
        assertEquals("""
                f.flow:1:12: error: unknown color '#chartreuse' (use blue, green, amber, red, purple, teal, pink, \
                orange, gray, or a hex value like #3366ff)
                    step b "B" #chartreuse
                               ^""", e.format("f.flow"));
    }
}
