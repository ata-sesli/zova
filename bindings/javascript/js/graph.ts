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
