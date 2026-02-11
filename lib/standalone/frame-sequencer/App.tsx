
import React, { useState } from 'react';
import Header from './components/Header';
import { GeminiService } from './services/geminiService';
import { AppState, VideoAnalysis } from './types';

const MODELS = [
  { id: 'gemini-3-flash-preview', name: 'Gemini 3 Flash' },
  { id: 'gemini-3-pro-preview', name: 'Gemini 3 Pro' },
  { id: 'gemini-2.5-flash-latest', name: 'Gemini 2.5 Flash' },
  { id: 'gemini-2.5-pro-latest', name: 'Gemini 2.5 Pro' },
];

const App: React.FC = () => {
  const [url, setUrl] = useState('https://www.youtube.com/watch?v=84AI0Qa1k8o');
  const [numClips, setNumClips] = useState(5);
  const [selectedModel, setSelectedModel] = useState(MODELS[0].id);
  const [appState, setAppState] = useState<AppState>(AppState.IDLE);
  const [analysis, setAnalysis] = useState<VideoAnalysis | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [copied, setCopied] = useState(false);

  const handleAnalyze = async () => {
    setAppState(AppState.ANALYZING);
    setError(null);
    setAnalysis(null);
    try {
      const result = await GeminiService.analyzeVideo(url, numClips, selectedModel);
      setAnalysis(result);
      setAppState(AppState.READY);
    } catch (e: any) {
      setError(e.message || "Neural extraction failed.");
      setAppState(AppState.ERROR);
    }
  };

  const handleCopy = () => {
    if (!analysis?.jsonOutput) return;
    navigator.clipboard.writeText(analysis.jsonOutput);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  };

  return (
    <div className="min-h-screen pb-20 bg-[#050505] text-zinc-300">
      <Header />

      <main className="max-w-5xl mx-auto px-6 mt-16">
        <section className="text-center mb-16">
          <h2 className="text-5xl font-black text-white uppercase tracking-tighter mb-4">
            Frame <span className="gradient-text">Sequencer</span>
          </h2>
          <p className="text-zinc-500 max-w-xl mx-auto text-sm font-medium">
            Deconstruct cinema into a clean visual prompt JSON sequence. 
            Automated subject injection for generation-ready data.
          </p>

          <div className="mt-12 flex flex-col md:flex-row gap-4 items-stretch justify-center">
            <input
              type="text"
              value={url}
              onChange={(e) => setUrl(e.target.value)}
              placeholder="YouTube URL..."
              className="flex-grow bg-zinc-900/50 border border-zinc-800 rounded-2xl px-6 py-4 outline-none focus:border-emerald-500 transition-all text-white font-mono"
            />
            
            <select
              value={selectedModel}
              onChange={(e) => setSelectedModel(e.target.value)}
              className="bg-zinc-900/50 border border-zinc-800 rounded-2xl px-4 py-4 outline-none focus:border-emerald-500 transition-all text-white font-mono text-xs cursor-pointer"
            >
              {MODELS.map(m => <option key={m.id} value={m.id}>{m.name}</option>)}
            </select>

            <div className="flex items-center bg-zinc-900/50 border border-zinc-800 rounded-2xl px-4 gap-2">
              <span className="text-[10px] font-black uppercase text-zinc-600 tracking-widest">Clips</span>
              <input
                type="number"
                min="1"
                max="15"
                value={numClips}
                onChange={(e) => setNumClips(parseInt(e.target.value) || 1)}
                className="w-12 bg-transparent text-white font-mono text-center outline-none"
              />
            </div>

            <button
              onClick={handleAnalyze}
              disabled={appState === AppState.ANALYZING}
              className="bg-white hover:bg-emerald-50 text-black font-black px-10 py-4 rounded-2xl transition-all active:scale-95 uppercase text-xs tracking-widest disabled:opacity-50"
            >
              {appState === AppState.ANALYZING ? 'Processing' : 'Generate JSON'}
            </button>
          </div>

          {error && (
            <div className="mt-8 text-red-500 text-xs font-bold uppercase tracking-widest bg-red-500/5 py-3 rounded-lg border border-red-500/20 max-w-lg mx-auto">
              {error}
            </div>
          )}
        </section>

        {appState === AppState.ANALYZING && (
          <div className="flex flex-col items-center justify-center py-20 gap-6">
            <div className="relative">
              <div className="w-16 h-16 border-4 border-emerald-500/10 border-t-emerald-500 rounded-full animate-spin"></div>
              <div className="absolute inset-0 flex items-center justify-center">
                <div className="w-2 h-2 bg-emerald-500 rounded-full animate-pulse"></div>
              </div>
            </div>
            <p className="text-[10px] font-black uppercase tracking-[0.4em] text-emerald-500/80 animate-pulse">Deconstructing Cinematic DNA</p>
          </div>
        )}

        {analysis && (
          <div className="animate-in fade-in slide-in-from-bottom-8 duration-1000">
            <div className="flex justify-between items-center mb-6">
              <h3 className="text-xs font-black uppercase tracking-[0.4em] text-white/30">Sequential Frame Output</h3>
              <button 
                onClick={handleCopy}
                className={`px-8 py-2.5 rounded-full text-[10px] font-black uppercase tracking-[0.2em] transition-all border ${
                  copied 
                  ? 'bg-emerald-500 border-emerald-500 text-black shadow-[0_0_20px_rgba(16,185,129,0.4)]' 
                  : 'bg-transparent border-zinc-800 text-zinc-500 hover:text-white hover:border-zinc-600'
                }`}
              >
                {copied ? 'Copied' : 'Copy JSON Sequence'}
              </button>
            </div>

            <div className="bg-zinc-900/20 border border-zinc-800 rounded-[2.5rem] p-10 shadow-inner relative overflow-hidden group">
              <div className="absolute top-0 left-0 w-full h-1 bg-gradient-to-r from-transparent via-emerald-500/20 to-transparent"></div>
              <pre className="font-mono text-[11px] leading-relaxed text-emerald-400/80 overflow-x-auto custom-scrollbar whitespace-pre-wrap max-h-[700px] overflow-y-auto pr-4">
                {analysis.jsonOutput}
              </pre>
            </div>

            <footer className="mt-20 pt-10 border-t border-zinc-900/50 text-center opacity-20 hover:opacity-40 transition-opacity">
               <p className="text-[8px] font-black uppercase tracking-[1.5em]">Neural Deconstruction Protocol // Verified Sequence</p>
            </footer>
          </div>
        )}
      </main>

      <style>{`
        .custom-scrollbar::-webkit-scrollbar { width: 4px; }
        .custom-scrollbar::-webkit-scrollbar-track { background: transparent; }
        .custom-scrollbar::-webkit-scrollbar-thumb { background: #1a1a1a; border-radius: 10px; }
        .custom-scrollbar::-webkit-scrollbar-thumb:hover { background: #333; }
        pre { scroll-behavior: smooth; }
      `}</style>
    </div>
  );
};

export default App;
