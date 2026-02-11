
export interface FramePrompt {
  id: string; // "001", "002", etc.
  visual_prompt: string; 
  char_in_this_scene: string[];
}

export interface VideoAnalysis {
  processedJson: FramePrompt[];
  jsonOutput: string;
}

export enum AppState {
  IDLE = 'IDLE',
  ANALYZING = 'ANALYZING',
  READY = 'READY',
  ERROR = 'ERROR'
}
