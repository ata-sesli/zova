// Internal transport for #41; the public Database facade belongs to #40.
export class WorkerChannel {
  #worker;
  #next = 1;
  #pending = new Map();
  #closed = false;
  #closing;

  get closed() { return this.#closed || Boolean(this.#closing); }

  constructor(worker) {
    this.#worker = worker;
    worker.addEventListener("message", event => {
      const reply = event.data;
      const pending = this.#pending.get(reply?.id);
      if (!pending) return;
      if (reply.fatal) { this.#fail(this.#error(reply.error)); return; }
      this.#pending.delete(reply.id);
      if (reply.ok) pending.resolve(reply.value);
      else pending.reject(this.#error(reply.error));
    });
    worker.addEventListener("error", event => this.#fail(new Error(event.message || "Worker failed")));
    worker.addEventListener("messageerror", () => this.#fail(new Error("Worker message could not be decoded")));
  }

  #error(info) {
    return Object.assign(new Error(info?.message || "Worker operation failed"), {
      status: info?.status, statusCode: info?.statusCode,
    });
  }

  #fail(error) {
    this.#closed = true;
    this.#worker.terminate();
    for (const pending of this.#pending.values()) pending.reject(error);
    this.#pending.clear();
  }

  request(operation, args = {}) {
    if (this.#closed || this.#closing) return Promise.reject(new Error("Database is closed"));
    const id = this.#next++;
    return new Promise((resolve, reject) => {
      this.#pending.set(id, { resolve, reject });
      try {
        // No transfer list: callers keep their buffers and queued values are copied.
        this.#worker.postMessage({ id, operation, args });
      } catch (error) {
        this.#pending.delete(id);
        reject(error);
      }
    });
  }

  close() {
    if (this.#closing) return this.#closing;
    if (this.#closed) return Promise.resolve();
    this.#closing = this.request("close").finally(() => {
      this.#fail(new Error("Database is closed"));
    });
    return this.#closing;
  }

  // All owned worker termination goes through this method so promises settle.
  terminate() { this.#fail(new Error("Worker terminated")); }
}
