import createModule from "../zova.mjs";
import { serveWorker } from "./runtime.mjs";
serveWorker(createModule);
