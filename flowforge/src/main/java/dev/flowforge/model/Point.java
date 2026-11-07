package dev.flowforge.model;

public record Point(double x, double y) {
    public Point plus(double dx, double dy) { return new Point(x + dx, y + dy); }
}
