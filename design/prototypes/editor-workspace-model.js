// Disposable prototype model. Every piece represents the program's linked video and audio.
(function (root, factory) {
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  root.StudioEditorModel = api;
})(globalThis, function () {
  const clone = pieces => pieces.map(piece => ({ ...piece }));

  class EditorTimeline {
    constructor(duration) {
      if (!Number.isFinite(duration) || duration <= 0) throw new Error('A positive source duration is required.');
      this.originalDuration = duration;
      this.pieces = [{ sourceStart: 0, sourceEnd: duration }];
      this.selection = null;
      this.undoStack = [];
      this.redoStack = [];
    }

    get duration() {
      return this.pieces.reduce((sum, piece) => sum + piece.sourceEnd - piece.sourceStart, 0);
    }

    select(start, end) {
      const a = Math.max(0, Math.min(this.duration, Math.min(start, end)));
      const b = Math.max(0, Math.min(this.duration, Math.max(start, end)));
      this.selection = Number.isFinite(a) && Number.isFinite(b) && b - a >= 0.01 ? { start: a, end: b } : null;
      return this.selection;
    }

    clearSelection() {
      this.selection = null;
    }

    outputToSource(time) {
      if (!Number.isFinite(time) || time < 0 || time > this.duration) return null;
      let offset = 0;
      for (const piece of this.pieces) {
        const length = piece.sourceEnd - piece.sourceStart;
        if (time < offset + length || (time === this.duration && time === offset + length)) {
          return piece.sourceStart + time - offset;
        }
        offset += length;
      }
      return null;
    }

    sourceToOutput(time) {
      if (!Number.isFinite(time)) return null;
      let offset = 0;
      for (const piece of this.pieces) {
        if (time >= piece.sourceStart && (time < piece.sourceEnd ||
            time === this.originalDuration && time === piece.sourceEnd)) {
          return offset + time - piece.sourceStart;
        }
        offset += piece.sourceEnd - piece.sourceStart;
      }
      return null;
    }

    sourceRangeToOutput(start, end) {
      const ranges = [];
      let offset = 0;
      for (const piece of this.pieces) {
        const a = Math.max(start, piece.sourceStart);
        const b = Math.min(end, piece.sourceEnd);
        if (b > a) ranges.push({ start: offset + a - piece.sourceStart, end: offset + b - piece.sourceStart });
        offset += piece.sourceEnd - piece.sourceStart;
      }
      return ranges;
    }

    cutSelection() {
      if (!this.selection) return false;
      const { start, end } = this.selection;
      const next = [];
      let offset = 0;
      for (const piece of this.pieces) {
        const length = piece.sourceEnd - piece.sourceStart;
        const left = Math.max(0, Math.min(length, start - offset));
        const right = Math.max(0, Math.min(length, offset + length - end));
        if (left > 0) next.push({ sourceStart: piece.sourceStart, sourceEnd: piece.sourceStart + left });
        if (right > 0) next.push({ sourceStart: piece.sourceEnd - right, sourceEnd: piece.sourceEnd });
        offset += length;
      }
      if (next.length === this.pieces.length && next.every((piece, i) => piece.sourceStart === this.pieces[i].sourceStart && piece.sourceEnd === this.pieces[i].sourceEnd)) return false;
      this.commit(next);
      return true;
    }

    moveSourceRangeBefore(start, end, before) {
      if (!(start >= 0 && end > start && end <= this.originalDuration) || before >= start && before < end) return false;
      const boundaries = [start, end, before];
      const split = this.pieces.flatMap(piece => {
        const points = [piece.sourceStart, ...boundaries.filter(time => time > piece.sourceStart && time < piece.sourceEnd).sort((a, b) => a - b), piece.sourceEnd];
        return points.slice(0, -1).map((point, i) => ({ sourceStart: point, sourceEnd: points[i + 1] }));
      });
      const moving = split.filter(piece => piece.sourceStart >= start && piece.sourceEnd <= end);
      const movingDuration = moving.reduce((sum, piece) => sum + piece.sourceEnd - piece.sourceStart, 0);
      if (Math.abs(movingDuration - (end - start)) > 0.001) return false;
      const rest = split.filter(piece => !moving.includes(piece));
      const target = rest.findIndex(piece => piece.sourceStart === before);
      if (target < 0) return false;
      rest.splice(target, 0, ...moving);
      this.commit(rest);
      return true;
    }

    commit(next) {
      this.undoStack.push(clone(this.pieces));
      this.redoStack = [];
      this.pieces = clone(next);
      this.clearSelection();
    }

    undo() {
      if (!this.undoStack.length) return false;
      this.redoStack.push(clone(this.pieces));
      this.pieces = this.undoStack.pop();
      this.clearSelection();
      return true;
    }

    redo() {
      if (!this.redoStack.length) return false;
      this.undoStack.push(clone(this.pieces));
      this.pieces = this.redoStack.pop();
      this.clearSelection();
      return true;
    }
  }

  return { EditorTimeline };
});
