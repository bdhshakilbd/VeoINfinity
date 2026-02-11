/**
 * Flow Frame Uploader - Browser Console Script v6
 * 
 * With network monitoring to verify uploads
 * 
 * PREREQUISITES:
 * 1. Run: python serve_frames.py (to start local server on port 8000)
 * 2. Open Flow page in "Frames to Video" mode
 * 3. Paste this entire script into browser console
 * 4. Press Enter
 */

(async () => {
    console.log('🎬 Flow Frame Uploader v6 Starting...');
    console.log('='.repeat(60));

    // Configuration
    const config = {
        firstFrameUrl: 'http://localhost:8000/frame_001.png',
        lastFrameUrl: 'http://localhost:8000/frame_002.png',
        prompt: 'Smooth cinematic transition between frames'
    };

    console.log('📁 First Frame:', config.firstFrameUrl);
    console.log('📁 Last Frame:', config.lastFrameUrl);
    console.log('📝 Prompt:', config.prompt);
    console.log('');

    // Track uploaded media IDs
    const uploadedMedia = [];

    // Intercept fetch to monitor uploads
    const originalFetch = window.fetch;
    window.fetch = async function (...args) {
        const response = await originalFetch.apply(this, args);

        // Check if this is an image upload
        const url = args[0];
        if (url && url.toString().includes('uploadUserImage')) {
            try {
                const clonedResponse = response.clone();
                const data = await clonedResponse.json();

                if (data.mediaGenerationId) {
                    uploadedMedia.push({
                        id: data.mediaGenerationId.mediaGenerationId,
                        width: data.width,
                        height: data.height
                    });
                    console.log('📡 UPLOAD DETECTED:');
                    console.log(`   Media ID: ${data.mediaGenerationId.mediaGenerationId.substring(0, 50)}...`);
                    console.log(`   Size: ${data.width}x${data.height}`);
                }
            } catch (e) {
                // Ignore parse errors
            }
        }

        return response;
    };

    /**
     * Fetch image from URL and convert to File object
     */
    async function urlToFile(url, filename) {
        try {
            const response = await originalFetch(url); // Use original fetch
            if (!response.ok) {
                throw new Error(`HTTP ${response.status}: ${response.statusText}`);
            }
            const blob = await response.blob();
            return new File([blob], filename, { type: 'image/png' });
        } catch (error) {
            console.error(`❌ Failed to fetch ${filename}:`, error.message);
            throw error;
        }
    }

    /**
     * Find file input element
     */
    function findFileInput() {
        return document.querySelector('input[type="file"]');
    }

    /**
     * Set file on input element and trigger events
     */
    function setFileOnInput(input, file) {
        const dataTransfer = new DataTransfer();
        dataTransfer.items.add(file);
        input.files = dataTransfer.files;

        input.dispatchEvent(new Event('change', { bubbles: true }));
        input.dispatchEvent(new Event('input', { bubbles: true }));

        console.log('   📤 File set on input');
    }

    /**
     * Click "Crop and Save" button in the crop dialog
     */
    async function clickCropAndSave() {
        await new Promise(r => setTimeout(r, 1500));

        const buttons = Array.from(document.querySelectorAll('button'));
        for (const btn of buttons) {
            if (btn.textContent.includes('Crop and Save')) {
                console.log('   ✂️  Clicking Crop and Save...');
                btn.click();
                await new Promise(r => setTimeout(r, 3000)); // Wait for upload
                return true;
            }
        }

        console.log('   ⚠️  Crop and Save button not found');
        return false;
    }

    /**
     * Upload to a specific button
     */
    async function uploadToButton(button, file, label) {
        console.log(`\n📸 Uploading ${label}: ${file.name}`);

        const uploadCountBefore = uploadedMedia.length;

        console.log(`   🖱️  Clicking ${label} button...`);
        button.click();
        await new Promise(r => setTimeout(r, 1000));

        const fileInput = findFileInput();
        if (fileInput) {
            setFileOnInput(fileInput, file);

            const cropped = await clickCropAndSave();
            if (cropped) {
                // Check if upload was successful
                if (uploadedMedia.length > uploadCountBefore) {
                    console.log(`   ✅ ${label} uploaded successfully!`);
                    return true;
                } else {
                    console.log(`   ⚠️  ${label} - Crop done but no upload detected`);
                }
            }
        } else {
            console.log('   ❌ No file input found');
        }

        return false;
    }

    try {
        // Step 1: Load images from localhost
        console.log('\n[1/5] Loading images from localhost...');
        const firstFile = await urlToFile(config.firstFrameUrl, 'frame_001.png');
        console.log('✅ First frame loaded:', firstFile.name, `(${(firstFile.size / 1024).toFixed(1)} KB)`);

        const lastFile = await urlToFile(config.lastFrameUrl, 'frame_002.png');
        console.log('✅ Last frame loaded:', lastFile.name, `(${(lastFile.size / 1024).toFixed(1)} KB)`);

        // Step 2: Find BOTH frame buttons FIRST
        console.log('\n[2/5] Finding frame buttons...');
        const frameButtons = Array.from(document.querySelectorAll('button.sc-d02e9a37-1.hvUQuN'));

        if (frameButtons.length < 2) {
            throw new Error(`Expected 2 frame buttons, found ${frameButtons.length}. Are you in "Frames to Video" mode?`);
        }

        const firstFrameButton = frameButtons[0];
        const lastFrameButton = frameButtons[1];
        console.log('✅ Found both frame buttons');

        // Step 3: Upload first frame
        console.log('\n[3/5] Uploading first frame...');
        await uploadToButton(firstFrameButton, firstFile, 'First Frame');
        await new Promise(r => setTimeout(r, 2000));

        // Step 4: Upload last frame
        console.log('\n[4/5] Uploading last frame...');
        await uploadToButton(lastFrameButton, lastFile, 'Last Frame');
        await new Promise(r => setTimeout(r, 2000));

        // Step 5: Set prompt and generate
        console.log('\n[5/5] Setting prompt and generating...');
        const textarea = document.querySelector('textarea');
        if (textarea) {
            textarea.value = config.prompt;
            textarea.dispatchEvent(new Event('input', { bubbles: true }));
            console.log('✅ Prompt set');
        }

        await new Promise(r => setTimeout(r, 500));

        // Find and click generate button
        const buttons = document.querySelectorAll('button');
        for (const btn of buttons) {
            if (btn.innerHTML.includes('arrow_forward')) {
                btn.click();
                console.log('✅ Generate button clicked!');
                break;
            }
        }

        // Summary
        console.log('\n' + '='.repeat(60));
        console.log('📊 UPLOAD SUMMARY:');
        console.log(`   Total uploads detected: ${uploadedMedia.length}`);

        if (uploadedMedia.length >= 2) {
            console.log('   ✅ Both frames uploaded successfully!');
            console.log('\n   Media IDs:');
            uploadedMedia.forEach((m, i) => {
                console.log(`   ${i + 1}. ${m.id.substring(0, 60)}...`);
                console.log(`      Size: ${m.width}x${m.height}`);
            });
        } else {
            console.log('   ⚠️  Expected 2 uploads, got ' + uploadedMedia.length);
        }

        console.log('\n' + '='.repeat(60));
        console.log('✅ PROCESS COMPLETE!');
        console.log('📹 Video generation should start shortly...');
        console.log('='.repeat(60));

        // Store for later use
        window.flowUploadedMedia = uploadedMedia;
        console.log('\n💡 Access uploaded media IDs: window.flowUploadedMedia');

    } catch (error) {
        console.error('\n❌ ERROR:', error.message);
        console.log('\n💡 Troubleshooting:');
        console.log('   1. Make sure local server is running (python serve_frames.py)');
        console.log('   2. Check that you are in "Frames to Video" mode');
    } finally {
        // Restore original fetch
        window.fetch = originalFetch;
    }
})();
