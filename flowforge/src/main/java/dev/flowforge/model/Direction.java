package dev.flowforge.model;

/** Layout direction: TB (top to bottom), LR (left to right), BT and RL are their mirrors. */
public enum Direction {
    TB, LR, BT, RL;

    public boolean horizontal() { return this == LR || this == RL; }

    public boolean reversed() { return this == BT || this == RL; }
}
