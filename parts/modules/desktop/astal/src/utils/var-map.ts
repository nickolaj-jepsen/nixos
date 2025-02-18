import type { Subscribable } from "astal/binding";
import { Gtk } from "astal/gtk4";

export class VarMap<K, T = Gtk.Widget> implements Subscribable {
  #subs = new Set<(v: T[]) => void>();
  protected map: Map<K, T>;

  #notifiy() {
    const value = this.get();
    for (const sub of this.#subs) {
      sub(value);
    }
  }

  #delete(key: K) {
    const v = this.map.get(key);

    if (v instanceof Gtk.Widget) {
      v.unparent();
    }

    this.map.delete(key);
  }

  constructor(initial?: Iterable<[K, T]>) {
    this.map = new Map(initial);
  }

  clear() {
    for (const key of this.map.keys()) {
      this.#delete(key);
    }
    this.#notifiy();
  }

  set(key: K, value: T) {
    this.#delete(key);
    this.map.set(key, value);
    this.#notifiy();
  }

  delete(key: K) {
    this.#delete(key);
    this.#notifiy();
  }

  get() {
    return [...this.map.values()];
  }

  subscribe(callback: (v: T[]) => void) {
    this.#subs.add(callback);
    return () => this.#subs.delete(callback);
  }
}
