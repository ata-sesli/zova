import { invalidArgument } from "./errors.js";

export type GraphTargetType =
  | "none"
  | "record"
  | "object"
  | "object-chunk"
  | "vector"
  | "entity"
  | "fact"
  | "concept"
  | "external";

export type GraphDirection = "outgoing" | "incoming";

export interface GraphInfo {
  name: string;
  nodeCount: bigint;
  edgeCount: bigint;
}

export interface GraphNodeInput {
  graphName: string;
  nodeId: string;
  kind: string;
  targetType: GraphTargetType;
  targetNamespace?: string;
  targetRef?: string;
}

export interface GraphNode extends GraphNodeInput {}

export interface GraphEdgeInput {
  graphName: string;
  fromNodeId: string;
  edgeType: string;
  toNodeId: string;
}

export interface GraphEdge extends GraphEdgeInput {}

export interface GraphNeighborsOptions {
  graphName: string;
  nodeId: string;
  direction: GraphDirection;
  edgeType?: string;
  limit: number;
}

export interface GraphNeighbor {
  nodeId: string;
  kind: string;
  edgeType: string;
}

export interface GraphDegreeOptions {
  graphName: string;
  nodeId: string;
  direction: GraphDirection;
  edgeType?: string;
}

export interface GraphWalkOptions {
  graphName: string;
  startNodeId: string;
  edgeType?: string;
  maxDepth: number;
  limit: number;
}

export interface GraphWalkItem {
  nodeId: string;
  kind: string;
  depth: number;
  predecessorNodeId?: string;
  edgeType?: string;
}

/** Graph node and edge keys: a `BigInt64Array` or an array of `bigint`. */
export type GraphKeys = BigInt64Array | readonly bigint[];

export interface GraphKeyedNode {
  nodeKey: bigint;
  nodeId: string;
  kind: string;
  createdOrder: bigint;
}

export interface GraphKeyedEdge {
  edgeKey: bigint;
  sourceNodeKey: bigint;
  edgeType: string;
  targetNodeKey: bigint;
  createdOrder: bigint;
}

export interface GraphKeyedNeighbor {
  edgeKey: bigint;
  neighborNodeKey: bigint;
  nodeId: string;
  kind: string;
  edgeType: string;
}

export interface GraphKeyedDegreeOptions {
  graphName: string;
  nodeKeys: GraphKeys;
  direction: GraphDirection;
  edgeType?: string;
}

export interface GraphEdgePayloadReplacement {
  edgeKey: bigint;
  payload: Uint8Array;
}

/** Scan position: continue after the last returned row's order and key. */
export interface GraphScanCursor {
  createdOrder: bigint;
  key: bigint;
}

export interface GraphScanOptions {
  graphName: string;
  /** Omit to start at the first node. */
  nodeAfter?: GraphScanCursor;
  /** Omit to start at the first edge. */
  edgeAfter?: GraphScanCursor;
  nodeLimit: number;
  edgeLimit: number;
}

export interface GraphScanPage {
  nodes: GraphKeyedNode[];
  edges: GraphKeyedEdge[];
  hasMoreNodes: boolean;
  hasMoreEdges: boolean;
}

export interface GraphWalkDirectionOptions {
  graphName: string;
  startNodeId: string;
  direction: GraphDirection;
  edgeType?: string;
  maxDepth: number;
  limit: number;
}

/** Where a directional walk spent its time; timings are milliseconds. */
export interface GraphWalkProfile {
  mutexWaitMs: number;
  rootLookupMs: number;
  adjacencyPrepareMs: number;
  adjacencyExecuteMs: number;
  bfsBookkeepingAllocationMs: number;
  cAbiResultExportMs: number;
  totalProfiledMs: number;
  frontierExpansions: number;
  adjacencyQueryBinds: number;
  adjacencyRowsStepped: number;
  resultCount: number;
}

export interface GraphWalkDirectionProfiled {
  items: GraphWalkItem[];
  profile: GraphWalkProfile;
}

export interface GraphFreshNodeInput {
  nodeId: string;
  kind: string;
  targetType: GraphTargetType;
  targetNamespace?: string;
  targetRef?: string;
}

/** An edge between two nodes of the same fresh build, by node position. */
export interface GraphFreshEdgeInput {
  fromNodeOrdinal: number;
  edgeType: string;
  toNodeOrdinal: number;
  /** Only `buildFreshGraphPreparedKeyedWithPayloads` and `FreshBuild.graph` accept payloads. */
  payload?: Uint8Array;
}

export interface GraphFreshKeys {
  /** Node keys in input order. */
  nodeKeys: BigInt64Array;
  /** Edge keys in input order; deduplicated edges repeat a key. */
  edgeKeys: BigInt64Array;
}

/** Copy keys into a `BigInt64Array`, rejecting values it would wrap. */
export function graphKeys(keys: GraphKeys): BigInt64Array {
  if (keys instanceof BigInt64Array) {
    return keys;
  }
  for (const key of keys) {
    if (BigInt.asIntN(64, key) !== key) {
      throw invalidArgument("graph keys must fit in a signed 64-bit integer");
    }
  }
  return BigInt64Array.from(keys);
}
