  Widget _buildListView() {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 100),
      controller: _scrollController,
      itemCount: _generatedHistory.length,
      itemBuilder: (context, index) {
        final item = _generatedHistory[index];
        final TextEditingController rowPromptController = TextEditingController(text: item.prompt);
        
        return Card(
          key: ValueKey('card_${item.id}_${item.isQueued}_${item.isLoading}_${item.imageBytes?.length ?? 0}'),
          elevation: 4,
          margin: const EdgeInsets.only(bottom: 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          child: Padding(
            padding: const EdgeInsets.all(12.0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // LEFT: Editable Prompt
                Expanded(
                  flex: 1,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TextField(
                        controller: rowPromptController,
                        maxLines: 4,
                        minLines: 2,
                        onChanged: (val) {
                          item.prompt = val; // Direct model update
                        },
                        style: const TextStyle(fontSize: 14),
                        decoration: InputDecoration(
                          labelText: 'Prompt ${index + 1}',
                          alignLabelWithHint: true,
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                          filled: true,
                          fillColor: Colors.grey.shade50,
                        ),
                      ),
                      const SizedBox(height: 8),
                      // Model and Style Selectors
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            // Model Picker
                            Container(
                              height: 36,
                              padding: const EdgeInsets.symmetric(horizontal: 8),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                border: Border.all(color: Colors.grey.shade300),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: DropdownButton<String>(
                                value: item.selectedModel ?? _selectedImageModel, // Use item override or global default
                                underline: const SizedBox(),
                                style: const TextStyle(fontSize: 12, color: Colors.black87),
                                items: const [
                                  DropdownMenuItem(value: 'GEM_PIX_2', child: Text('GEM PIX 2')),
                                  DropdownMenuItem(value: 'IMAGEN_3_5', child: Text('Imagen 3.5')),
                                ],
                                onChanged: (val) {
                                  if (val != null) {
                                    setState(() => item.selectedModel = val);
                                  }
                                },
                              ),
                            ),
                            const SizedBox(width: 8),
                            // Style Picker
                            Container(
                              height: 36,
                              padding: const EdgeInsets.symmetric(horizontal: 8),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                border: Border.all(color: Colors.grey.shade300),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: DropdownButton<String>(
                                value: item.selectedStyle ?? 'None',
                                underline: const SizedBox(),
                                style: const TextStyle(fontSize: 12, color: Colors.black87),
                                items: const [
                                  DropdownMenuItem(value: 'None', child: Text('No Style')),
                                  DropdownMenuItem(value: 'Realistic', child: Text('Realistic')),
                                  DropdownMenuItem(value: 'Cartoon', child: Text('Cartoon')),
                                  DropdownMenuItem(value: '3D Render', child: Text('3D Render')),
                                  DropdownMenuItem(value: 'Oil Painting', child: Text('Oil Painting')),
                                  DropdownMenuItem(value: 'Sketch', child: Text('Sketch')),
                                  DropdownMenuItem(value: 'Anime', child: Text('Anime')),
                                ],
                                onChanged: (val) {
                                  if (val != null) {
                                    setState(() => item.selectedStyle = val);
                                  }
                                },
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        children: [
                          if (!item.isLoading && !item.isQueued)
                            ElevatedButton.icon(
                              onPressed: () {
                                item.prompt = rowPromptController.text;
                                _retryGeneration(item); 
                              },
                              icon: const Icon(Icons.refresh, size: 16),
                              label: Text(item.imageBytes == null ? 'Generate' : 'Regenerate'),
                            ),
                          
                          // Context Toggle
                          Tooltip(
                            message: 'Include previous 5 prompts for scene consistency',
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Transform.scale(
                                  scale: 0.8,
                                  child: Switch(
                                    value: item.includeContext ?? false,
                                    onChanged: (val) => setState(() => item.includeContext = val),
                                    activeColor: Colors.blue,
                                  ),
                                ),
                                const Text('Context', style: TextStyle(fontSize: 12, color: Colors.black54)),
                              ],
                            ),
                          ),
                        ],
                      ),

                       if (item.error != null)
                         Padding(
                           padding: const EdgeInsets.only(top: 8),
                           child: Row(
                             children: [
                               Icon(Icons.error_outline, color: Colors.red.shade700, size: 16),
                               const SizedBox(width: 4),
                               Expanded(
                                 child: Text(
                                   item.error!,
                                   style: TextStyle(color: Colors.red.shade700, fontSize: 12),
                                 ),
                               ),
                             ],
                           ),
                         ),
                    ],
                  ),
                ),
                
                const SizedBox(width: 16),
                
                // RIGHT: Image Display
                Expanded(
                  flex: 1,
                  child: AspectRatio(
                    aspectRatio: 16/9,
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.grey.shade200,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.grey.shade300),
                      ),
                      child: item.isLoading || item.isQueued
                          ? Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  CircularProgressIndicator(
                                    color: item.isQueued ? Colors.orange : Theme.of(context).primaryColor,
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    item.isQueued ? 'Queued (${_pendingQueue.indexOf(item.id) + 1})' : 'Generating...',
                                    style: TextStyle(
                                      color: item.isQueued ? Colors.orange : Theme.of(context).primaryColor,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ],
                              ),
                            )
                          : item.imageBytes != null 
                              ? Stack(
                                  children: [
                                     ClipRRect(
                                      borderRadius: BorderRadius.circular(8),
                                      child: RobustImageDisplay(
                                        id: item.id,
                                        imageBytes: item.imageBytes!,
                                        imageFile: item.imagePath,
                                        fit: BoxFit.contain,
                                      ),
                                    ),
                                    Positioned(
                                      top: 8,
                                      right: 8,
                                      child: IconButton(
                                        icon: const Icon(Icons.delete, color: Colors.white),
                                        style: IconButton.styleFrom(backgroundColor: Colors.black54),
                                        onPressed: () => _deleteHistoryItem(item.id),
                                      ),
                                    ),
                                  ],
                                )
                              : const Center(child: Text('No Image', style: TextStyle(color: Colors.grey))),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildGridView() {
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 100),
      controller: _scrollController,
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: _gridColumns,
        crossAxisSpacing: 16,
        mainAxisSpacing: 16,
        childAspectRatio: 1.0, // Square cells for grid
      ),
      itemCount: _generatedHistory.length,
      itemBuilder: (context, index) {
        final item = _generatedHistory[index];
        return Card(
           key: ValueKey('grid_card_${item.id}_${item.isQueued}_${item.isLoading}'),
           elevation: 2,
           shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
           clipBehavior: Clip.antiAlias,
           child: Stack(
             fit: StackFit.expand,
             children: [
               // Image or Placeholder
               if (item.imageBytes != null)
                 RobustImageDisplay(
                    id: item.id,
                    imageBytes: item.imageBytes!,
                    imageFile: item.imagePath,
                    fit: BoxFit.cover,
                 )
               else
                 Container(color: Colors.grey.shade200),
               
               // Loading / Status Overlay
               if (item.isLoading || item.isQueued)
                 Container(
                   color: Colors.black54,
                   child: Center(
                     child: CircularProgressIndicator(
                       color: item.isQueued ? Colors.orange : Colors.white,
                     ),
                   ),
                 ),

               // Info Footer Overlay
               Positioned(
                 left: 0, right: 0, bottom: 0,
                 child: Container(
                   padding: const EdgeInsets.all(8),
                   decoration: const BoxDecoration(
                     gradient: LinearGradient(
                       begin: Alignment.bottomCenter,
                       end: Alignment.topCenter,
                       colors: [Colors.black87, Colors.transparent],
                     ),
                   ),
                   child: Column(
                     crossAxisAlignment: CrossAxisAlignment.start,
                     mainAxisSize: MainAxisSize.min,
                     children: [
                       Text(
                         item.prompt,
                         maxLines: 2,
                         overflow: TextOverflow.ellipsis,
                         style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                       ),
                       const SizedBox(height: 4),
                       Row(
                         mainAxisAlignment: MainAxisAlignment.spaceBetween,
                         children: [
                            if (!item.isLoading)
                              InkWell(
                                onTap: () => _retryGeneration(item),
                                child: const Icon(Icons.refresh, color: Colors.white, size: 16),
                              ),
                            InkWell(
                              onTap: () => _deleteHistoryItem(item.id),
                              child: const Icon(Icons.delete, color: Colors.white70, size: 16),
                            ),
                         ],
                       )
                     ],
                   ),
                 ),
               ),
               
               // Error Overlay
               if (item.error != null)
                  Positioned(
                    top: 8, left: 8, right: 8,
                    child: Container(
                      padding: const EdgeInsets.all(4),
                      color: Colors.red.withOpacity(0.9),
                      child: Text(
                        item.error!,
                        style: const TextStyle(color: Colors.white, fontSize: 10),
                        maxLines: 3, 
                        overflow: TextOverflow.ellipsis
                      ),
                    ),
                  )
             ],
           ),
        );
      },
    );
  }
