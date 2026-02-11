
import React from 'react';

const Header: React.FC = () => {
  return (
    <header className="py-8 px-6 border-b border-emerald-900/30 bg-black/40 backdrop-blur-md sticky top-0 z-50">
      <div className="max-w-7xl mx-auto flex items-center justify-between">
        <div className="flex items-center gap-3">
          <div className="w-10 h-10 bg-emerald-500 rounded-lg flex items-center justify-center shadow-[0_0_15px_rgba(16,185,129,0.5)]">
            <svg className="w-6 h-6 text-black" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M15 10l4.553-2.276A1 1 0 0121 8.618v6.764a1 1 0 01-1.447.894L15 14M5 18h8a2 2 0 002-2V8a2 2 0 00-2-2H5a2 2 0 00-2 2v8a2 2 0 002 2z" />
            </svg>
          </div>
          <h1 className="text-2xl font-bold tracking-tight">
            Cine<span className="text-emerald-400">Recreate</span>
          </h1>
        </div>
        <div className="hidden md:flex items-center gap-6 text-sm font-medium text-gray-400">
          <span className="hover:text-emerald-400 cursor-pointer transition-colors">Analyzer</span>
          <span className="hover:text-emerald-400 cursor-pointer transition-colors">Prompt Generator</span>
          <span className="hover:text-emerald-400 cursor-pointer transition-colors">Veo Forge</span>
        </div>
      </div>
    </header>
  );
};

export default Header;
