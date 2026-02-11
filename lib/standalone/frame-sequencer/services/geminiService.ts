
import { GoogleGenAI, Type } from "@google/genai";
import { VideoAnalysis, FramePrompt } from "../types";

export class GeminiService {
  private static getAI() {
    return new GoogleGenAI({ apiKey: process.env.API_KEY || '' });
  }

  static async analyzeVideo(url: string, numClips: number = 5, modelName: string = 'gemini-3-flash-preview'): Promise<VideoAnalysis> {
    const ai = this.getAI();
    
    const contents = {
      parts: [
        {
          fileData: {
            fileUri: url,
            mimeType: 'video/mp4'
          }
        },
        {
          text: `Deconstruct this video into ${numClips} distinct visual scenes/keyframes.
          
          TASK 1: CHARACTER PROFILING
          Identify every key character. Provide an EXTREMELY DETAILED, standalone physical description for each (face, body, clothes, style, accessories). 
          The description must be thorough enough for an AI to generate the character from scratch without external context.
          Assign IDs: [CHAR_1], [CHAR_2], etc.
          
          TASK 2: SCENE GENERATION
          Generate a flat array of keyframes representing these scenes.
          
          For each frame, provide:
          - description: A vivid visual description of the action/composition using Character IDs (e.g., "[CHAR_1] is standing next to [CHAR_2]").
          - char_ids: An array of the Character IDs present in this specific frame.
          
          OUTPUT FORMAT:
          Strict JSON.`
        }
      ]
    };

    const response = await ai.models.generateContent({
      model: modelName,
      contents: contents,
      config: {
        responseMimeType: "application/json",
        responseSchema: {
          type: Type.OBJECT,
          properties: {
            characters: {
              type: Type.ARRAY,
              items: {
                type: Type.OBJECT,
                properties: {
                  id: { type: Type.STRING },
                  description: { type: Type.STRING }
                },
                required: ["id", "description"]
              }
            },
            frames: {
              type: Type.ARRAY,
              items: {
                type: Type.OBJECT,
                properties: {
                  description: { type: Type.STRING },
                  char_ids: { 
                    type: Type.ARRAY,
                    items: { type: Type.STRING }
                  }
                },
                required: ["description", "char_ids"]
              }
            }
          },
          required: ["characters", "frames"]
        }
      }
    });

    try {
      const data = JSON.parse(response.text || '{}');
      let counter = 1;

      // Create a map for fast character lookup
      const charMap = new Map<string, string>();
      (data.characters || []).forEach((char: any) => {
        charMap.set(char.id, char.description);
      });

      const processedJson: FramePrompt[] = data.frames.map((frame: any) => {
        const frameId = String(counter++).padStart(3, '0');
        
        let visual_prompt = frame.description;
        const charInScene: string[] = [];

        // 1. Replace IDs in visual_prompt with full descriptions for self-containment
        charMap.forEach((desc, id) => {
             const escapedId = id.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
             const regex = new RegExp(escapedId, 'g');
             visual_prompt = visual_prompt.replace(regex, `(${desc})`);
        });

        // 2. Build char_in_this_scene array by mapping IDs to descriptions
        if (frame.char_ids && Array.isArray(frame.char_ids)) {
            frame.char_ids.forEach((id: string) => {
                const desc = charMap.get(id);
                if (desc) {
                    charInScene.push(desc);
                }
            });
        }

        return {
          id: frameId,
          visual_prompt,
          char_in_this_scene: charInScene
        };
      });

      return {
        processedJson,
        jsonOutput: JSON.stringify(processedJson, null, 2)
      };
    } catch (e) {
      console.error("Neural Parse Error", e);
      throw new Error("The neural trace was corrupted. Please verify the source video and try again.");
    }
  }
}
