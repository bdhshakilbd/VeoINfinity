// ADD THIS METHOD after line 1453 (_pasteJson)

Future<void> _pickStyleImage() async {
  final result = await FilePicker.platform.pickFiles(
    type: FileType.image,
    allowMultiple: false,
  );
  
  if (result != null && result.files.isNotEmpty) {
    final filePath = result.files.first.path;
    if (filePath != null) {
      setState(() {
        _styleImagePath = filePath;
        _uploadedStyleInput = null; // Clear cache when new image selected
      });
      _log('🎨 Style image selected: ${path.basename(filePath)}');
    }
  }
}

// MODIFY THE GENERATION LOGIC in _startApiSceneGeneration around line 4085-4134
// ADD STYLE IMAGE UPLOAD LOGIC after the ref image pre-upload section

// Pre-upload style image if selected (MEDIA_CATEGORY_STYLE)
if (_cdpRunning && _styleImagePath != null && _uploadedStyleInput == null) {
  _log('🎨 Pre-uploading style image...');
  
  try {
    final styleFile = File(_styleImagePath!);
    if (await styleFile.exists()) {
      final styleBytes = await styleFile.readAsBytes();
      final styleB64 = base64Encode(styleBytes);
      
      final styleWorkflowId = _googleImageApi!.getNewWorkflowId();
      final uploaded = await _googleImageApi!.uploadImageWithCaption(
        base64Image: styleB64,
        workflowId: styleWorkflowId,
        mediaCategory: 'MEDIA_CATEGORY_STYLE',
      );
      
      _uploadedStyleInput = RecipeMediaInput(
        caption: uploaded.caption,
        mediaCategory: 'MEDIA_CATEGORY_STYLE',
        mediaGenerationId: uploaded.mediaGenerationId,
      );
      
      _log('✅ Style image uploaded successfully');
    }
  } catch (e) {
    _log('⚠️ Failed to upload style image: $e');
  }
}

// THEN IN THE GENERATION LOOP around line 4150-4190
// MODIFY to add style to recipeInputs:

            if (refImages != null && refImages.isNotEmpty) {
              _log('⏳ Scene $sceneNum: Uploading ${refImages.length} ref images...');
              
              final workflowId = _googleImageApi!.getNewWorkflowId();
              
              // Collect subject reference inputs
              final recipeInputs = <RecipeMediaInput>[];
              for (int idx = 0; idx < refImages.length; idx++) {
                final b64 = refImages[idx];
                
                if (_uploadedRefImageCache.containsKey(b64)) {
                  recipeInputs.add(_uploadedRefImageCache[b64]!);
                  _log('  ♻️ Reusing cached ref image ${idx + 1}');
                  continue;
                }
                
                try {
                  final uploaded = await _googleImageApi!.uploadImageWithCaption(
                    base64Image: b64,
                    workflowId: workflowId,
                    mediaCategory: 'MEDIA_CATEGORY_SUBJECT',
                  );
                  
                  final input = RecipeMediaInput(
                    caption: uploaded.caption,
                    mediaCategory: 'MEDIA_CATEGORY_SUBJECT',
                    mediaGenerationId: uploaded.mediaGenerationId,
                  );
                  
                  _uploadedRefImageCache[b64] = input;
                  recipeInputs.add(input);
                  _log('  📤 Uploaded ref image ${idx + 1}/${refImages.length}');
                } catch (e) {
                  _log('  ⚠️ Failed to upload ref image ${idx + 1}: $e');
                }
              }
              
              // ADD STYLE IMAGE TO THE END if available
              if (_uploadedStyleInput != null) {
                recipeInputs.add(_uploadedStyleInput!);
                _log('  🎨 Added style image to recipe');
              }
              
              if (recipeInputs.isEmpty) {
                _log('⏳ Scene $sceneNum: Generating (no refs available)...');
                response = await _retryApiCall(() => _googleImageApi!.generateImage(
                  prompt: prompt,
                  aspectRatio: aspectRatio,
                  imageModel: apiModelId,
                ));
              } else {
                _log('⏳ Scene $sceneNum: Generating with ${recipeInputs.length} inputs (${recipeInputs.where((i) => i.mediaCategory == "MEDIA_CATEGORY_STYLE").length} style)...');
                response = await _retryApiCall(() => _googleImageApi!.runImageRecipe(
                  userInstruction: prompt,
                  recipeMediaInputs: recipeInputs,
                  workflowId: workflowId,
                  aspectRatio: aspectRatio,
                  imageModel: apiModelId,
                ));
              }
            } else {
              // No ref images, but check for style
              if (_uploadedStyleInput != null) {
                final workflowId = _googleImageApi!.getNewWorkflowId();
                _log('⏳ Scene $sceneNum: Generating with style only...');
                response = await _retryApiCall(() => _googleImageApi!.runImageRecipe(
                  userInstruction: prompt,
                  recipeMediaInputs: [_uploadedStyleInput!],
                  workflowId: workflowId,
                  aspectRatio: aspectRatio,
                  imageModel: apiModelId,
                ));
              } else {
                // No refs, no style
                _log('⏳ Scene $sceneNum: Generating via API...');
                response = await _retryApiCall(() => _googleImageApi!.generateImage(
                  prompt: prompt,
                  aspectRatio: aspectRatio,
                  imageModel: apiModelId,
                ));
              }
            }
