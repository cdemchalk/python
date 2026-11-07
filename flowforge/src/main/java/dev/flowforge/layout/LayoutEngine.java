package dev.flowforge.layout;

import dev.flowforge.layout.LayoutResult.Bounds;
import dev.flowforge.layout.LayoutResult.EdgeRoute;
import dev.flowforge.layout.LayoutResult.GroupBox;
import dev.flowforge.layout.LayoutResult.NodeBox;
import dev.flowforge.model.Diagram;
import dev.flowforge.model.Direction;
import dev.flowforge.model.Edge;
import dev.flowforge.model.Group;
import dev.flowforge.model.Node;
import dev.flowforge.model.NodeType;
import dev.flowforge.model.Point;

import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Comparator;
import java.util.Deque;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Layered (Sugiyama-style) layout:
 * <ol>
 *   <li>cycle breaking by DFS (back edges are reversed for layout only),</li>
 *   <li>longest-path ranking, with sources pulled down next to their successors,</li>
 *   <li>dummy nodes for edges spanning several ranks,</li>
 *   <li>barycenter crossing reduction (alternating sweeps + adjacent swaps), keeping groups contiguous and
 *       lanes in order,</li>
 *   <li>coordinate assignment by repeated weighted isotonic regression (pool-adjacent-violators) toward the
 *       neighbors' positions, which yields straight edges where possible without overlaps,</li>
 *   <li>manual {@code @pos} overrides, edge routing as smooth cubic curves, group and lane boxes.</li>
 * </ol>
 * All work is done in a "TB space" (cross axis = x, main axis = y) and transformed for LR/BT/RL.
 */
public final class LayoutEngine {
    public static final double MARGIN = 32;
    static final double NODE_SEP = 40, RANK_SEP = 64, DUMMY_SEP = 18, GROUP_PAD = 16, GROUP_HEADER = 24,
            LANE_PAD = 28, LANE_HEADER = 38, TITLE_H = 40, LABEL_FONT = 12;

    public LayoutResult layout(Diagram d) { return new Run(d).run(); }

    public static double[] labelSize(String label) {
        int lines = TextMetrics.lines(label).length;
        return new double[]{TextMetrics.maxLineWidth(label, LABEL_FONT) + 18, lines * 15 + 7};
    }

    private enum Side {
        TOP(0, -1), BOTTOM(0, 1), LEFT(-1, 0), RIGHT(1, 0);
        final double nx, ny;

        Side(double nx, double ny) { this.nx = nx; this.ny = ny; }

        boolean vertical() { return this == TOP || this == BOTTOM; }
    }

    /** A node of the layered graph: a real node or a dummy on a long edge. */
    private static final class V {
        int real = -1, edge = -1, rank, lane = -1, group = -1, pos;
        double cross, crossSize, mainSize, vx, vy;
        boolean labelDummy;
        final List<Integer> up = new ArrayList<>(), down = new ArrayList<>();
    }

    private record E(int index, int from, int to, Edge edge, boolean self, boolean[] reversed, List<Integer> chain) {}

    private static final class Run {
        final Diagram d;
        final Direction dir;
        final boolean horiz;
        final List<Node> nodes;
        final int n;
        final Map<String, Integer> index = new HashMap<>();
        final double[] w, h;
        final int[] rank, groupOf, laneOf;
        final List<Group> lanes = new ArrayList<>(), boxes = new ArrayList<>();
        final List<E> edges = new ArrayList<>();
        final List<V> vs = new ArrayList<>();
        List<List<Integer>> layers = new ArrayList<>();
        double mainStart, mainEnd;
        final Map<Integer, double[]> laneBands = new LinkedHashMap<>();

        Run(Diagram d) {
            this.d = d;
            this.dir = d.direction();
            this.horiz = dir.horizontal();
            this.nodes = d.nodes();
            this.n = nodes.size();
            w = new double[n];
            h = new double[n];
            rank = new int[n];
            groupOf = new int[n];
            laneOf = new int[n];
            Arrays.fill(groupOf, -1);
            Arrays.fill(laneOf, -1);
            for (int i = 0; i < n; i++) {
                Node nd = nodes.get(i);
                index.put(nd.id(), i);
                double[] s = Shapes.size(nd.type(), nd.label());
                w[i] = s[0];
                h[i] = s[1];
            }
            for (Group g : d.groups()) (g.lane() ? lanes : boxes).add(g);
            for (int gi = 0; gi < boxes.size(); gi++)
                for (String m : boxes.get(gi).members()) {
                    Integer i = index.get(m);
                    if (i != null && groupOf[i] < 0) groupOf[i] = gi;
                }
            for (int li = 0; li < lanes.size(); li++)
                for (String m : lanes.get(li).members()) {
                    Integer i = index.get(m);
                    if (i != null && laneOf[i] < 0) laneOf[i] = li;
                }
            List<Edge> es = d.edges();
            for (int i = 0; i < es.size(); i++) {
                Edge e = es.get(i);
                int a = index.get(e.from()), b = index.get(e.to());
                edges.add(new E(i, a, b, e, a == b, new boolean[1], new ArrayList<>()));
            }
        }

        LayoutResult run() {
            breakCycles();
            assignRanks();
            buildLayers();
            orderLayers();
            assignCross();
            assignMain();
            toVisual();
            List<NodeBox> boxesOut = nodeBoxes();
            List<EdgeRoute> routes = routeEdges(boxesOut);
            List<GroupBox> groups = groupBoxes(boxesOut);
            return finish(boxesOut, routes, groups);
        }

        // ------------------------------------------------------------ 1. cycle breaking

        void breakCycles() {
            List<List<E>> out = new ArrayList<>();
            int[] indeg = new int[n];
            for (int i = 0; i < n; i++) out.add(new ArrayList<>());
            for (E e : edges)
                if (!e.self) {
                    out.get(e.from).add(e);
                    indeg[e.to]++;
                }
            List<Integer> roots = new ArrayList<>();
            for (int i = 0; i < n; i++) if (nodes.get(i).type() == NodeType.START) roots.add(i);
            for (int i = 0; i < n; i++) if (indeg[i] == 0 && !roots.contains(i)) roots.add(i);
            for (int i = 0; i < n; i++) if (!roots.contains(i)) roots.add(i);
            int[] state = new int[n];
            for (int root : roots) {
                if (state[root] != 0) continue;
                Deque<int[]> stack = new ArrayDeque<>();
                stack.push(new int[]{root, 0});
                state[root] = 1;
                while (!stack.isEmpty()) {
                    int[] top = stack.peek();
                    List<E> o = out.get(top[0]);
                    if (top[1] >= o.size()) {
                        state[top[0]] = 2;
                        stack.pop();
                        continue;
                    }
                    E e = o.get(top[1]++);
                    if (state[e.to] == 1) e.reversed[0] = true;
                    else if (state[e.to] == 0) {
                        state[e.to] = 1;
                        stack.push(new int[]{e.to, 0});
                    }
                }
            }
        }

        int dagFrom(E e) { return e.reversed[0] ? e.to : e.from; }

        int dagTo(E e) { return e.reversed[0] ? e.from : e.to; }

        // ------------------------------------------------------------ 2. ranking

        void assignRanks() {
            List<List<Integer>> out = new ArrayList<>();
            int[] indeg = new int[n];
            for (int i = 0; i < n; i++) out.add(new ArrayList<>());
            for (E e : edges)
                if (!e.self) {
                    out.get(dagFrom(e)).add(dagTo(e));
                    indeg[dagTo(e)]++;
                }
            int[] deg = indeg.clone();
            List<Integer> topo = new ArrayList<>();
            Deque<Integer> q = new ArrayDeque<>();
            for (int i = 0; i < n; i++) if (deg[i] == 0) q.add(i);
            while (!q.isEmpty()) {
                int u = q.poll();
                topo.add(u);
                for (int v : out.get(u)) if (--deg[v] == 0) q.add(v);
            }
            for (int u : topo) for (int v : out.get(u)) rank[v] = Math.max(rank[v], rank[u] + 1);
            // Pull sources (e.g. notes, side inputs) down next to their first successor.
            for (int u : topo) {
                if (indeg[u] == 0 && !out.get(u).isEmpty() && nodes.get(u).type() != NodeType.START) {
                    int min = Integer.MAX_VALUE;
                    for (int v : out.get(u)) min = Math.min(min, rank[v]);
                    rank[u] = Math.max(rank[u], min - 1);
                }
            }
        }

        // ------------------------------------------------------------ 3. layered graph

        V real(int i) { return vs.get(i); }

        void buildLayers() {
            for (int i = 0; i < n; i++) {
                V v = new V();
                v.real = i;
                v.rank = rank[i];
                v.crossSize = horiz ? h[i] : w[i];
                v.mainSize = horiz ? w[i] : h[i];
                v.lane = laneOf[i];
                v.group = groupOf[i];
                vs.add(v);
            }
            for (E e : edges) {
                if (e.self) continue;
                int a = dagFrom(e), b = dagTo(e);
                int span = rank[b] - rank[a];
                e.chain.add(a);
                for (int k = 1; k < span; k++) {
                    V dv = new V();
                    dv.edge = e.index;
                    dv.rank = rank[a] + k;
                    dv.lane = laneOf[e.from];
                    if (e.edge.label() != null && k == span / 2) {
                        double[] ls = labelSize(e.edge.label());
                        dv.labelDummy = true;
                        dv.crossSize = horiz ? ls[1] : ls[0];
                        dv.mainSize = horiz ? ls[0] : ls[1];
                    }
                    vs.add(dv);
                    e.chain.add(vs.size() - 1);
                }
                e.chain.add(b);
                for (int k = 0; k + 1 < e.chain.size(); k++) {
                    vs.get(e.chain.get(k)).down.add(e.chain.get(k + 1));
                    vs.get(e.chain.get(k + 1)).up.add(e.chain.get(k));
                }
            }
            int maxRank = 0;
            for (V v : vs) maxRank = Math.max(maxRank, v.rank);
            for (int r = 0; r <= maxRank; r++) layers.add(new ArrayList<>());
            for (int i = 0; i < vs.size(); i++) layers.get(vs.get(i).rank).add(i);
            updatePos();
        }

        void updatePos() {
            for (List<Integer> layer : layers) for (int p = 0; p < layer.size(); p++) vs.get(layer.get(p)).pos = p;
        }

        // ------------------------------------------------------------ 4. crossing reduction

        void orderLayers() {
            List<List<Integer>> best = copy(layers);
            int bestCross = crossings();
            for (int it = 0; it < 24 && bestCross > 0; it++) {
                sweep(it % 2 == 0);
                transpose();
                int c = crossings();
                if (c < bestCross) {
                    bestCross = c;
                    best = copy(layers);
                }
            }
            if (bestCross == 0 && layers.size() > 0) { // still settle a single sweep for tidy initial order
                sweep(true);
                transpose();
                if (crossings() > 0) layers = best;
            } else {
                layers = best;
            }
            updatePos();
        }

        static List<List<Integer>> copy(List<List<Integer>> ls) {
            List<List<Integer>> c = new ArrayList<>();
            for (List<Integer> l : ls) c.add(new ArrayList<>(l));
            return c;
        }

        void sweep(boolean down) {
            int L = layers.size();
            for (int k = 1; k < L; k++) {
                int li = down ? k : L - 1 - k;
                List<Integer> layer = layers.get(li);
                Map<Integer, Double> bary = new HashMap<>();
                for (int v : layer) {
                    List<Integer> nb = down ? vs.get(v).up : vs.get(v).down;
                    if (nb.isEmpty()) bary.put(v, (double) vs.get(v).pos);
                    else bary.put(v, nb.stream().mapToDouble(u -> vs.get(u).pos).average().orElse(0));
                }
                sortLayer(layer, bary);
            }
            updatePos();
        }

        void sortLayer(List<Integer> layer, Map<Integer, Double> bary) {
            Map<Integer, double[]> cluster = new HashMap<>();
            for (int v : layer) {
                int g = vs.get(v).group;
                if (g >= 0) {
                    double[] acc = cluster.computeIfAbsent(g, k -> new double[2]);
                    acc[0] += bary.get(v);
                    acc[1]++;
                }
            }
            int laneLast = lanes.size();
            Comparator<Integer> cmp = Comparator
                    .<Integer>comparingInt(v -> vs.get(v).lane < 0 ? laneLast : vs.get(v).lane)
                    .thenComparingDouble(v -> {
                        int g = vs.get(v).group;
                        return g >= 0 ? cluster.get(g)[0] / cluster.get(g)[1] : bary.get(v);
                    })
                    .thenComparingInt(v -> vs.get(v).group)
                    .thenComparingDouble(bary::get)
                    .thenComparingInt(v -> vs.get(v).pos);
            layer.sort(cmp);
        }

        void transpose() {
            boolean improved = true;
            for (int guard = 0; improved && guard < 8; guard++) {
                improved = false;
                for (List<Integer> layer : layers) {
                    for (int i = 0; i + 1 < layer.size(); i++) {
                        V a = vs.get(layer.get(i)), b = vs.get(layer.get(i + 1));
                        if (a.lane != b.lane || a.group != b.group) continue;
                        if (pairCrossings(b, a) < pairCrossings(a, b)) {
                            int ai = layer.get(i), bi = layer.get(i + 1);
                            layer.set(i, bi);
                            layer.set(i + 1, ai);
                            a.pos = i + 1;
                            b.pos = i;
                            improved = true;
                        }
                    }
                }
            }
            updatePos();
        }

        /** Crossings between edges of {@code a} and {@code b} when {@code a} is left of {@code b}. */
        int pairCrossings(V a, V b) {
            int c = 0;
            for (int x : a.up) for (int y : b.up) if (vs.get(x).pos > vs.get(y).pos) c++;
            for (int x : a.down) for (int y : b.down) if (vs.get(x).pos > vs.get(y).pos) c++;
            return c;
        }

        int crossings() {
            int total = 0;
            for (int li = 0; li + 1 < layers.size(); li++) {
                List<int[]> es = new ArrayList<>();
                for (int v : layers.get(li)) for (int u : vs.get(v).down) es.add(new int[]{vs.get(v).pos, vs.get(u).pos});
                for (int i = 0; i < es.size(); i++)
                    for (int j = i + 1; j < es.size(); j++) {
                        int[] p = es.get(i), q = es.get(j);
                        if ((p[0] - q[0]) * (p[1] - q[1]) < 0) total++;
                    }
            }
            return total;
        }

        // ------------------------------------------------------------ 5. coordinates

        double sep(V a, V b) {
            boolean ra = a.real >= 0, rb = b.real >= 0;
            double gap = ra && rb ? NODE_SEP : (!ra && !rb ? DUMMY_SEP : (NODE_SEP + DUMMY_SEP) / 2);
            if (a.labelDummy || b.labelDummy) gap = Math.max(gap, 24);
            if (a.group != b.group) {
                gap += (a.group >= 0 ? GROUP_PAD : 0) + (b.group >= 0 ? GROUP_PAD : 0);
                if (horiz && b.group >= 0) gap += GROUP_HEADER;
            }
            if (a.lane != b.lane) gap += 2 * LANE_PAD;
            return (a.crossSize + b.crossSize) / 2 + gap;
        }

        void assignCross() {
            for (List<Integer> layer : layers) {
                double x = 0;
                for (int i = 0; i < layer.size(); i++) {
                    V v = vs.get(layer.get(i));
                    x = i == 0 ? v.crossSize / 2 : x + sep(vs.get(layer.get(i - 1)), v);
                    v.cross = x;
                }
            }
            int L = layers.size();
            for (int it = 0; it < 10; it++) {
                for (int li = 1; li < L; li++) place(layers.get(li), 1);
                for (int li = L - 2; li >= 0; li--) place(layers.get(li), 2);
            }
            for (int it = 0; it < 3; it++) for (int li = 0; li < L; li++) place(layers.get(li), 3);
            shiftLanes();
            double min = Double.MAX_VALUE;
            for (V v : vs) min = Math.min(min, v.cross - v.crossSize / 2);
            for (double[] b : laneBands.values()) min = Math.min(min, b[0]);
            double shift = MARGIN - min;
            for (V v : vs) v.cross += shift;
            for (double[] b : laneBands.values()) {
                b[0] += shift;
                b[1] += shift;
            }
        }

        /** mode 1: toward upper neighbors, 2: lower, 3: both. */
        void place(List<Integer> layer, int mode) {
            int k = layer.size();
            if (k == 0) return;
            double[] target = new double[k], weight = new double[k], offset = new double[k];
            for (int i = 0; i < k; i++) {
                V v = vs.get(layer.get(i));
                List<Integer> nb = new ArrayList<>();
                if (mode != 2) nb.addAll(v.up);
                if (mode != 1) nb.addAll(v.down);
                if (nb.isEmpty()) {
                    target[i] = v.cross;
                    weight[i] = 0.05;
                } else {
                    target[i] = nb.stream().mapToDouble(u -> vs.get(u).cross).average().orElse(v.cross);
                    weight[i] = v.real >= 0 ? 1 : 2;
                    if (v.group >= 0) target[i] = clampToGroup(v, target[i]);
                }
                if (i > 0) offset[i] = offset[i - 1] + sep(vs.get(layer.get(i - 1)), v);
            }
            double[] t = new double[k];
            for (int i = 0; i < k; i++) t[i] = target[i] - offset[i];
            double[] y = isotonic(t, weight);
            for (int i = 0; i < k; i++) vs.get(layer.get(i)).cross = y[i] + offset[i];
            keepOutOfGroups(layer);
        }

        /**
         * Pushes real nodes that are not members of a group out of the group's band in the ranks the group
         * spans, so group backgrounds never cover foreign nodes. Members keep their positions.
         */
        void keepOutOfGroups(List<Integer> layer) {
            if (boxes.isEmpty() || layer.isEmpty()) return;
            int r = vs.get(layer.get(0)).rank;
            for (int g = 0; g < boxes.size(); g++) {
                double lo = Double.MAX_VALUE, hi = -Double.MAX_VALUE;
                int rMin = Integer.MAX_VALUE, rMax = -1;
                for (int i = 0; i < n; i++)
                    if (groupOf[i] == g) {
                        V v = vs.get(i);
                        lo = Math.min(lo, v.cross - v.crossSize / 2);
                        hi = Math.max(hi, v.cross + v.crossSize / 2);
                        rMin = Math.min(rMin, v.rank);
                        rMax = Math.max(rMax, v.rank);
                    }
                if (r < rMin || r > rMax) continue;
                double pad = GROUP_PAD + NODE_SEP / 2 + (horiz ? GROUP_HEADER : 0);
                int first = -1, last = -1;
                for (int i = 0; i < layer.size(); i++)
                    if (vs.get(layer.get(i)).group == g) {
                        if (first < 0) first = i;
                        last = i;
                    }
                double mid = (lo + hi) / 2;
                int leftEnd = 0; // nodes [0, leftEnd) go left of the group, [rightStart, size) go right
                if (first >= 0) leftEnd = first;
                else while (leftEnd < layer.size() && vs.get(layer.get(leftEnd)).cross < mid) leftEnd++;
                int rightStart = first >= 0 ? last + 1 : leftEnd;
                for (int i = 0; i < layer.size(); i++) {
                    V v = vs.get(layer.get(i));
                    if (v.real < 0 || v.group == g) continue;
                    if (i < leftEnd) v.cross = Math.min(v.cross, lo - pad - v.crossSize / 2);
                    else if (i >= rightStart) v.cross = Math.max(v.cross, hi + pad + v.crossSize / 2);
                }
                for (int i = leftEnd - 2; i >= 0; i--) {
                    V x = vs.get(layer.get(i)), y = vs.get(layer.get(i + 1));
                    x.cross = Math.min(x.cross, y.cross - sep(x, y));
                }
                for (int i = Math.max(1, rightStart + 1); i < layer.size(); i++) {
                    V x = vs.get(layer.get(i - 1)), y = vs.get(layer.get(i));
                    y.cross = Math.max(y.cross, x.cross + sep(x, y));
                }
            }
        }

        /**
         * Keeps a group member's target within the extent of its fellow members, so a group cannot chase
         * outside nodes that are themselves pushed away from the group.
         */
        double clampToGroup(V v, double target) {
            double lo = Double.MAX_VALUE, hi = -Double.MAX_VALUE;
            for (int i = 0; i < n; i++) {
                V o = vs.get(i);
                if (groupOf[i] != v.group || o == v) continue;
                lo = Math.min(lo, o.cross - o.crossSize / 2 + v.crossSize / 2);
                hi = Math.max(hi, o.cross + o.crossSize / 2 - v.crossSize / 2);
            }
            if (lo == Double.MAX_VALUE) return target;
            if (lo > hi) return (lo + hi) / 2;
            return Math.max(lo, Math.min(hi, target));
        }

        /** Weighted isotonic regression (non-decreasing fit) by pool-adjacent-violators. */
        static double[] isotonic(double[] t, double[] w) {
            int k = t.length;
            double[] sw = new double[k], swt = new double[k];
            int[] cnt = new int[k];
            int top = -1;
            for (int i = 0; i < k; i++) {
                top++;
                sw[top] = w[i];
                swt[top] = w[i] * t[i];
                cnt[top] = 1;
                while (top > 0 && swt[top - 1] / sw[top - 1] > swt[top] / sw[top]) {
                    sw[top - 1] += sw[top];
                    swt[top - 1] += swt[top];
                    cnt[top - 1] += cnt[top];
                    top--;
                }
            }
            double[] y = new double[k];
            int p = 0;
            for (int b = 0; b <= top; b++) for (int c = 0; c < cnt[b]; c++) y[p++] = swt[b] / sw[b];
            return y;
        }

        /** Moves each lane's nodes into its own band, in lane order. */
        void shiftLanes() {
            if (lanes.isEmpty()) return;
            double offset = 0;
            for (int li = 0; li < lanes.size(); li++) offset = shiftLane(li, offset);
            shiftLane(-1, offset); // nodes outside every lane go last
        }

        double shiftLane(int lane, double offset) {
            double min = Double.MAX_VALUE, max = -Double.MAX_VALUE;
            for (V v : vs)
                if (v.lane == lane) {
                    min = Math.min(min, v.cross - v.crossSize / 2);
                    max = Math.max(max, v.cross + v.crossSize / 2);
                }
            if (min == Double.MAX_VALUE) return offset;
            double shift = offset + LANE_PAD - min;
            for (V v : vs) if (v.lane == lane) v.cross += shift;
            double end = max + shift + LANE_PAD;
            if (lane >= 0) laneBands.put(lane, new double[]{offset, end});
            return end;
        }

        void assignMain() {
            int L = layers.size();
            double[] size = new double[L];
            for (V v : vs) size[v.rank] = Math.max(size[v.rank], v.mainSize);
            boolean rev = dir.reversed();
            int[] gMin = new int[boxes.size()], gMax = new int[boxes.size()];
            Arrays.fill(gMin, Integer.MAX_VALUE);
            Arrays.fill(gMax, -1);
            for (int i = 0; i < n; i++)
                if (groupOf[i] >= 0) {
                    gMin[groupOf[i]] = Math.min(gMin[groupOf[i]], rank[i]);
                    gMax[groupOf[i]] = Math.max(gMax[groupOf[i]], rank[i]);
                }
            double header = horiz ? 0 : GROUP_HEADER;
            double[] gap = new double[L];
            for (int li = 1; li < L; li++) {
                double extra = 0, label = 0;
                for (int g = 0; g < boxes.size(); g++) {
                    if (gMin[g] == li) extra = Math.max(extra, GROUP_PAD + (rev ? 0 : header));
                    if (gMax[g] == li - 1) extra = Math.max(extra, GROUP_PAD + (rev ? header : 0));
                    if (gMin[g] == li && gMax[g] == li - 1) extra = Math.max(extra, 2 * GROUP_PAD + header);
                }
                for (E e : edges)
                    if (!e.self && e.edge.label() != null && rank[dagTo(e)] == li && rank[dagFrom(e)] == li - 1) {
                        double[] ls = labelSize(e.edge.label());
                        label = Math.max(label, (horiz ? ls[0] : ls[1]) + 30);
                    }
                gap[li] = Math.max(RANK_SEP, label) + extra;
            }
            double start = MARGIN + (lanes.isEmpty() ? 0 : LANE_HEADER);
            double first = 0;
            for (int g = 0; g < boxes.size(); g++)
                if (gMin[g] == 0 && !rev || gMax[g] == L - 1 && rev) first = GROUP_PAD + header;
            mainStart = start + first;
            double[] center = new double[L];
            double y = mainStart;
            for (int li = 0; li < L; li++) {
                if (li > 0) y += gap[li];
                center[li] = y + size[li] / 2;
                y += size[li];
            }
            mainEnd = y;
            for (V v : vs) {
                double m = center[v.rank];
                v.vy = rev ? mainStart + mainEnd - m : m; // main coordinate (temporarily in vy)
            }
        }

        void toVisual() {
            for (V v : vs) {
                double m = v.vy, c = v.cross;
                if (horiz) {
                    v.vx = m;
                    v.vy = c;
                } else {
                    v.vx = c;
                    v.vy = m;
                }
            }
            for (int i = 0; i < n; i++) {
                Point p = d.positions().get(nodes.get(i).id());
                if (p != null) {
                    vs.get(i).vx = p.x();
                    vs.get(i).vy = p.y();
                }
            }
        }

        List<NodeBox> nodeBoxes() {
            List<NodeBox> out = new ArrayList<>();
            for (int i = 0; i < n; i++) {
                Node nd = nodes.get(i);
                V v = vs.get(i);
                out.add(new NodeBox(nd.id(), nd.type(), nd.label(), nd.color(), round(v.vx), round(v.vy), w[i], h[i],
                        rank[i], d.positions().containsKey(nd.id())));
            }
            return out;
        }

        static double round(double v) { return Math.round(v * 10) / 10.0; }

        // ------------------------------------------------------------ 6. edge routing

        Side forward() {
            return switch (dir) {
                case TB -> Side.BOTTOM;
                case BT -> Side.TOP;
                case LR -> Side.RIGHT;
                case RL -> Side.LEFT;
            };
        }

        static Side opposite(Side s) {
            return switch (s) {
                case TOP -> Side.BOTTOM;
                case BOTTOM -> Side.TOP;
                case LEFT -> Side.RIGHT;
                case RIGHT -> Side.LEFT;
            };
        }

        double mainOf(Point p) {
            double m = horiz ? p.x() : p.y();
            return dir.reversed() ? -m : m;
        }

        static Side toward(NodeBox b, Point p) {
            double dx = (p.x() - b.x()) / (b.w() / 2), dy = (p.y() - b.y()) / (b.h() / 2);
            if (Math.abs(dx) > Math.abs(dy)) return dx > 0 ? Side.RIGHT : Side.LEFT;
            return dy > 0 ? Side.BOTTOM : Side.TOP;
        }

        private record End(int edge, int node, Side side, double ref, boolean source) {}

        List<EdgeRoute> routeEdges(List<NodeBox> nb) {
            Map<Integer, List<Point>> interior = new HashMap<>();
            Map<Integer, Point> labelAt = new HashMap<>();
            List<End> ends = new ArrayList<>();
            for (E e : edges) {
                if (e.self) continue;
                NodeBox a = nb.get(e.from), b = nb.get(e.to);
                boolean pinned = a.pinned() || b.pinned();
                List<Point> mid = new ArrayList<>();
                if (!pinned) {
                    List<Integer> ch = new ArrayList<>(e.chain.subList(1, e.chain.size() - 1));
                    if (e.reversed[0]) java.util.Collections.reverse(ch);
                    for (int vi : ch) {
                        V v = vs.get(vi);
                        Point p = new Point(v.vx, v.vy);
                        mid.add(p);
                        if (v.labelDummy) labelAt.put(e.index, p);
                    }
                }
                interior.put(e.index, mid);
                Point next = mid.isEmpty() ? new Point(b.x(), b.y()) : mid.get(0);
                Point prev = mid.isEmpty() ? new Point(a.x(), a.y()) : mid.get(mid.size() - 1);
                Side sa, sb;
                if (pinned) {
                    sa = toward(a, next);
                    sb = toward(b, prev);
                } else {
                    sa = mainOf(next) > mainOf(new Point(a.x(), a.y())) ? forward() : opposite(forward());
                    sb = mainOf(prev) < mainOf(new Point(b.x(), b.y())) ? opposite(forward()) : forward();
                }
                ends.add(new End(e.index, e.from, sa, sa.vertical() ? next.x() : next.y(), true));
                ends.add(new End(e.index, e.to, sb, sb.vertical() ? prev.x() : prev.y(), false));
            }
            // Spread edge ends that share a node side.
            Map<String, List<End>> bySide = new LinkedHashMap<>();
            for (End en : ends) bySide.computeIfAbsent(en.node + ":" + en.side, k -> new ArrayList<>()).add(en);
            Map<String, Point> port = new HashMap<>();
            Map<String, Side> portSide = new HashMap<>();
            for (List<End> group : bySide.values()) {
                group.sort(Comparator.comparingDouble(End::ref).thenComparingInt(End::edge)
                        .thenComparing(End::source));
                NodeBox b = nb.get(group.get(0).node);
                Side s = group.get(0).side;
                double len = s.vertical() ? b.w() : b.h();
                if (b.type() == NodeType.START || b.type() == NodeType.END) len = s.vertical() ? b.w() - b.h() : b.h() * 0.5;
                int k = group.size();
                double spacing = b.type() == NodeType.DECIDE || k == 1 ? 0 : Math.min(18, len * 0.8 / (k - 1));
                for (int i = 0; i < k; i++) {
                    End en = group.get(i);
                    double off = (i - (k - 1) / 2.0) * spacing;
                    double px = b.x() + s.nx * b.w() / 2, py = b.y() + s.ny * b.h() / 2;
                    if (s == Side.BOTTOM && b.type() == NodeType.DOC) py -= 6;
                    if (s.vertical()) px += off;
                    else py += off;
                    port.put(en.edge + ":" + en.source, new Point(px, py));
                    portSide.put(en.edge + ":" + en.source, s);
                }
            }
            List<EdgeRoute> out = new ArrayList<>();
            for (E e : edges) {
                String label = e.edge.label();
                double[] ls = label == null ? new double[]{0, 0} : labelSize(label);
                if (e.self) {
                    out.add(selfLoop(e, nb.get(e.from), ls));
                    continue;
                }
                List<Point> pts = new ArrayList<>();
                pts.add(port.get(e.index + ":true"));
                pts.addAll(interior.get(e.index));
                pts.add(port.get(e.index + ":false"));
                Side s0 = portSide.get(e.index + ":true"), s1 = portSide.get(e.index + ":false");
                List<Point> tan = new ArrayList<>();
                tan.add(new Point(s0.nx, s0.ny));
                for (int i = 1; i + 1 < pts.size(); i++) {
                    double dm = mainOf(pts.get(i + 1)) - mainOf(pts.get(i - 1));
                    Side f = forward();
                    double sg = dm >= 0 ? 1 : -1;
                    tan.add(new Point(f.nx * sg, f.ny * sg));
                }
                tan.add(new Point(-s1.nx, -s1.ny));
                PathData.Builder pb = PathData.builder().m(pts.get(0).x(), pts.get(0).y());
                List<Point[]> segs = new ArrayList<>();
                for (int i = 0; i + 1 < pts.size(); i++) {
                    Point p = pts.get(i), q = pts.get(i + 1), t0 = tan.get(i), t1 = tan.get(i + 1);
                    double dx = q.x() - p.x(), dy = q.y() - p.y();
                    double dist = Math.hypot(dx, dy);
                    double l0 = Math.max(Math.min(12, dist / 3), 0.5 * Math.abs(dx * t0.x() + dy * t0.y()));
                    double l1 = Math.max(Math.min(12, dist / 3), 0.5 * Math.abs(dx * t1.x() + dy * t1.y()));
                    Point c1 = new Point(p.x() + t0.x() * l0, p.y() + t0.y() * l0);
                    Point c2 = new Point(q.x() - t1.x() * l1, q.y() - t1.y() * l1);
                    pb.c(c1, c2, q);
                    segs.add(new Point[]{p, c1, c2, q});
                }
                Point lp = null;
                if (label != null) {
                    lp = labelAt.get(e.index);
                    if (lp == null) {
                        int s = segs.size();
                        lp = s % 2 == 0 ? pts.get(s / 2) : bezier(segs.get(s / 2), 0.5);
                    }
                }
                out.add(new EdgeRoute(e.index, e.edge.from(), e.edge.to(), label, e.edge.style(), pb.build(), lp,
                        ls[0], ls[1]));
            }
            return out;
        }

        EdgeRoute selfLoop(E e, NodeBox b, double[] ls) {
            PathData.Builder pb = PathData.builder();
            Point lp;
            if (!horiz) {
                double r = b.right() - (b.type() == NodeType.DECIDE ? b.w() * 0.25 : 0);
                double y0 = b.y() - Math.min(12, b.h() / 4), y1 = b.y() + Math.min(12, b.h() / 4);
                if (b.type() == NodeType.DECIDE) {
                    y0 = b.y() - b.h() / 4;
                    y1 = b.y() + b.h() / 4;
                }
                pb.m(r, y0).c(r + 56, y0 - 30, r + 56, y1 + 30, r, y1);
                lp = new Point(r + 46 + ls[0] / 2, b.y());
            } else {
                double bt = b.bottom() - (b.type() == NodeType.DECIDE ? b.h() * 0.25 : 0);
                double x0 = b.x() + Math.min(14, b.w() / 4), x1 = b.x() - Math.min(14, b.w() / 4);
                pb.m(x0, bt).c(x0 + 30, bt + 56, x1 - 30, bt + 56, x1, bt);
                lp = new Point(b.x(), bt + 48 + ls[1] / 2);
            }
            return new EdgeRoute(e.index, e.edge.from(), e.edge.to(), e.edge.label(), e.edge.style(), pb.build(),
                    e.edge.label() == null ? null : lp, ls[0], ls[1]);
        }

        static Point bezier(Point[] s, double t) {
            double u = 1 - t;
            double x = u * u * u * s[0].x() + 3 * u * u * t * s[1].x() + 3 * u * t * t * s[2].x() + t * t * t * s[3].x();
            double y = u * u * u * s[0].y() + 3 * u * u * t * s[1].y() + 3 * u * t * t * s[2].y() + t * t * t * s[3].y();
            return new Point(x, y);
        }

        // ------------------------------------------------------------ 7. groups, bounds

        List<GroupBox> groupBoxes(List<NodeBox> nb) {
            List<GroupBox> out = new ArrayList<>();
            double mainLo = MARGIN, mainHi = mainEnd + LANE_PAD;
            for (int li = 0; li < lanes.size(); li++) {
                Group g = lanes.get(li);
                double[] band = laneBands.get(li);
                double lo = band == null ? Double.MAX_VALUE : band[0], hi = band == null ? -Double.MAX_VALUE : band[1];
                for (String m : g.members()) {
                    NodeBox b = nb.get(index.get(m));
                    if (b.pinned() || band == null) {
                        lo = Math.min(lo, (horiz ? b.top() : b.left()) - LANE_PAD);
                        hi = Math.max(hi, (horiz ? b.bottom() : b.right()) + LANE_PAD);
                    }
                }
                if (lo == Double.MAX_VALUE) continue;
                if (horiz) {
                    out.add(new GroupBox(g.id(), g.label(), g.color(), true, mainLo, lo, mainHi - mainLo, hi - lo,
                            mainLo + LANE_HEADER / 2, (lo + hi) / 2, true, li));
                } else {
                    out.add(new GroupBox(g.id(), g.label(), g.color(), true, lo, mainLo, hi - lo, mainHi - mainLo,
                            (lo + hi) / 2, mainLo + LANE_HEADER / 2, false, li));
                }
            }
            for (Group g : boxes) {
                double x0 = Double.MAX_VALUE, y0 = Double.MAX_VALUE, x1 = -Double.MAX_VALUE, y1 = -Double.MAX_VALUE;
                for (String m : g.members()) {
                    NodeBox b = nb.get(index.get(m));
                    x0 = Math.min(x0, b.left());
                    y0 = Math.min(y0, b.top());
                    x1 = Math.max(x1, b.right());
                    y1 = Math.max(y1, b.bottom());
                }
                if (x0 == Double.MAX_VALUE) continue;
                x0 -= GROUP_PAD;
                x1 += GROUP_PAD;
                y0 -= GROUP_PAD + GROUP_HEADER;
                y1 += GROUP_PAD;
                out.add(new GroupBox(g.id(), g.label(), g.color(), false, x0, y0, x1 - x0, y1 - y0, x0 + 12,
                        y0 + 16, false, -1));
            }
            return out;
        }

        LayoutResult finish(List<NodeBox> nb, List<EdgeRoute> routes, List<GroupBox> groups) {
            double x0 = Double.MAX_VALUE, y0 = Double.MAX_VALUE, x1 = -Double.MAX_VALUE, y1 = -Double.MAX_VALUE;
            for (NodeBox b : nb) {
                x0 = Math.min(x0, b.left());
                y0 = Math.min(y0, b.top());
                x1 = Math.max(x1, b.right());
                y1 = Math.max(y1, b.bottom());
            }
            for (GroupBox g : groups) {
                x0 = Math.min(x0, g.x());
                y0 = Math.min(y0, g.y());
                x1 = Math.max(x1, g.x() + g.w());
                y1 = Math.max(y1, g.y() + g.h());
            }
            for (EdgeRoute r : routes) {
                for (Point p : r.path().points()) {
                    x0 = Math.min(x0, p.x());
                    y0 = Math.min(y0, p.y());
                    x1 = Math.max(x1, p.x());
                    y1 = Math.max(y1, p.y());
                }
                if (r.labelPos() != null) {
                    x0 = Math.min(x0, r.labelPos().x() - r.labelW() / 2);
                    x1 = Math.max(x1, r.labelPos().x() + r.labelW() / 2);
                    y0 = Math.min(y0, r.labelPos().y() - r.labelH() / 2);
                    y1 = Math.max(y1, r.labelPos().y() + r.labelH() / 2);
                }
            }
            if (x0 == Double.MAX_VALUE) {
                x0 = y0 = MARGIN;
                x1 = y1 = MARGIN + 120;
            }
            double bx = x0 - MARGIN, by = y0 - MARGIN, bw = x1 - x0 + 2 * MARGIN, bh = y1 - y0 + 2 * MARGIN;
            Point titlePos = null;
            if (d.title() != null && !d.title().isBlank()) {
                by -= TITLE_H;
                bh += TITLE_H;
                titlePos = new Point(bx + MARGIN, by + MARGIN + 6);
                bw = Math.max(bw, TextMetrics.width(d.title(), 18) * 1.05 + 2 * MARGIN);
            }
            return new LayoutResult(d.title(), dir, nb, routes, groups,
                    new Bounds(Math.floor(bx), Math.floor(by), Math.ceil(bw), Math.ceil(bh)), titlePos);
        }
    }
}
