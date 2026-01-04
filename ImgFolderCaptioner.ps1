# ImgFolderCaptioner
# by: theFisher86
# Version: 3.0

# Requires: PowerShell 7+ for System.Drawing.Common compatibility

# Max image size in bytes (3.5MB)
$maxSize = 3.5MB

# Load the appropriate System.Drawing assembly based on PowerShell version
if ($PSVersionTable.PSVersion.Major -ge 6) {
    Add-Type -AssemblyName System.Drawing.Common
} else {
    Add-Type -AssemblyName System.Drawing
}

# Set your NanoGPT API key from apikey.txt file
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$apiKeyFile = Join-Path $scriptDir "apikey.txt"

if (Test-Path $apiKeyFile) {
    $apiKey = Get-Content $apiKeyFile -First 1
    $apiKey = $apiKey.Trim()
    if ($apiKey -eq "") {
        Write-Host "ERROR: apikey.txt file is empty."
        Write-Host "Please add your API key to: $apiKeyFile"
        exit 1
    }
} else {
    Write-Host "ERROR: apikey.txt file not found."
    Write-Host "Please create an apikey.txt file in the script directory with your API key."
    Write-Host "Expected location: $apiKeyFile"
    exit 1
}

# Variable to store trigger word
$triggerWord = ""

# Variable to store individual file creation preference
$createIndividualFiles = $false

# Variable to store mode for captions.txt: 'overwrite', 'append', or 'skip'
$captionsFileMode = 'overwrite'

# Variable to store whether to prepend trigger word to captions
$prependTriggerWord = $false

# Hash table to store already captioned images (for append mode)
$capturedImages = @{}

# Variables for wordbank system
$wordbankFile = ""  # Will be set after directory selection
$characterDescription = ""
$characterTraits = ""

# Function: Resize image until under size limit
function Resize-ImageToLimit {
    param(
        [string]$Path,
        [int]$MaxBytes
    )

    $img = [System.Drawing.Image]::FromFile($Path)
    $quality = 90

    do {
        $stream = New-Object System.IO.MemoryStream
        $encoder = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() |
                   Where-Object { $_.MimeType -eq "image/jpeg" }

        $params = New-Object System.Drawing.Imaging.EncoderParameters(1)
        $params.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter(
            [System.Drawing.Imaging.Encoder]::Quality, $quality
        )

        $img.Save($stream, $encoder, $params)
        $bytes = $stream.ToArray()
        $size = $bytes.Length

        $quality -= 10
    } while ($size -gt $MaxBytes -and $quality -gt 10)

    $img.Dispose()
    return $bytes
}

# Function: Clean AI response by removing special markup tags
function Clean-AIResponse {
    param(
        [string]$Response
    )
    
    # Remove common AI markup tags
    $cleaned = $Response -replace "<\|.*?\|>", ""
    $cleaned = $cleaned -replace ""
    
    # Remove leading/trailing whitespace
    $cleaned = $cleaned.Trim()
    
    # If the response is a comma-separated list, remove empty entries at start/end
    if ($cleaned -match '^\s*,+') {
        $cleaned = $cleaned -replace '^\s*,+\s*', ''
    }
    if ($cleaned -match ',+\s*$') {
        $cleaned = $cleaned -replace ',+\s*$', ''
    }
    
    return $cleaned
}

# Function: Generate character wordbank
function Generate-CharacterWordbank {
    param(
        [string]$TriggerWord
    )
    
    Write-Host ""
    Write-Host "Generating character wordbank..."
    Write-Host ""
    
    # Look for character files (character1, character2, etc.)
    $characterFiles = Get-ChildItem -Path . -File | 
                   Where-Object { $_.Name -match '^character\d+\.' -and $_.Extension -match '\.(png|jpg|jpeg|webp)$' } |
                   Sort-Object Name
    
    # If no character files found, ask if user wants to use all files
    if ($characterFiles.Count -eq 0) {
        Write-Host "No character files (character1, character2, etc.) found."
        Write-Host ""
        $useAllFiles = Read-Host "Use all files in directory as character reference? (Y/N, default: N)"
        
        if ($useAllFiles -eq 'Y' -or $useAllFiles -eq 'y') {
            # Use all image files except captions.txt and wordbank.txt
            $characterFiles = Get-ChildItem -Path . -File | 
                           Where-Object { $_.Extension -match '\.(png|jpg|jpeg|webp)$' } |
                           Sort-Object Name
        } else {
            Write-Host "Skipping character wordbank generation."
            return $false
        }
    }
    
    if ($characterFiles.Count -eq 0) {
        Write-Host "No character reference images available. Skipping wordbank generation."
        return $false
    }
    
    Write-Host "Found $($characterFiles.Count) character reference image(s)."
    Write-Host "Analyzing character..."
    Write-Host ""
    
    # Build content array with character images (limit to stay under 4.5MB)
    $contentArray = @(
        @{ 
            type = "text"; 
            text = "Describe character in attached images. All of images are of same character. Create a 1 sentence description of character which focuses on their visual appearance and style. Focus on traits that are consistent throughout images. Describe character as accurately, descriptively and succinctly as possible.`n`nFollowing your character description include 3 line breaks and then a comma-separated list of 15-25 one to two word traits, adjectives and/or descriptors of character that can be used as a word bank for future descriptions of character."
        }
    )
    
    # Calculate text content size
    $payloadSize = 0
    $textJson = @{ 
        type = "text"; 
        text = "Describe character in attached images. All of images are of same character. Create a 1 sentence description of character which focuses on their visual appearance and style. Focus on traits that are consistent throughout images. Describe character as accurately, descriptively and succinctly as possible.`n`nFollowing your character description include 3 line breaks and then a comma-separated list of 15-25 one to two word traits, adjectives and/or descriptors of character that can be used as a word bank for future descriptions of character."
    } | ConvertTo-Json -Depth 10
    $payloadSize += [System.Text.Encoding]::UTF8.GetByteCount($textJson)
    
    Write-Host "Initial text content size: $([math]::Round($payloadSize / 1MB, 2)) MB"
    
    # Add character images to content (stop before reaching 4.3MB)
    $maxPayloadSize = 4.3MB
    $imagesIncluded = 0
    
    foreach ($file in $characterFiles) {
        # Resize and convert to base64
        $bytes = Resize-ImageToLimit -Path $file.FullName -MaxBytes $maxSize
        $base64 = [Convert]::ToBase64String($bytes)
        
        # Calculate size of this image
        $imageJson = @{
            type = "image_url"
            image_url = @{ url = "data:image/jpeg;base64,$base64" }
        } | ConvertTo-Json -Depth 10
        $imageSize = [System.Text.Encoding]::UTF8.GetByteCount($imageJson)
        
        # Check if adding this image would exceed limit
        if ($payloadSize + $imageSize -ge $maxPayloadSize) {
            Write-Host "Payload would exceed $($maxPayloadSize / 1MB)MB with this image."
            Write-Host "Stopping at $imagesIncluded image(s) to stay under limit."
            break
        }
        
        # Add image to content
        $contentArray += @{
            type = "image_url"
            image_url = @{ url = "data:image/jpeg;base64,$base64" }
        }
        
        $payloadSize += $imageSize
        $imagesIncluded++
        
        Write-Host "Added: $($file.Name) (Image size: $([math]::Round($imageSize / 1MB, 2)) MB, Total: $([math]::Round($payloadSize / 1MB, 2)) MB)"
    }
    
    Write-Host ""
    Write-Host "Final payload size: $([math]::Round($payloadSize / 1MB, 2)) MB ($imagesIncluded images)"
    Write-Host ""
    
    # Build JSON payload
    $payload = @{
        model = "glm-4.6v"
        messages = @(
            @{
                role = "user"
                content = $contentArray
            }
        )
        stream = $false
    } | ConvertTo-Json -Depth 10
    
    # Write-Host "Full prompt sent to AI provider:"
    # Write-Host $contentArray[0].text
    # Write-Host ""

    Write-Host "Processing..."
    
    # Send request
    try {
        $response = Invoke-RestMethod `
            -Uri "https://nano-gpt.com/api/v1/chat/completions" `
            -Method POST `
            -Headers @{
                "Authorization" = "Bearer $apiKey"
                "Content-Type"  = "application/json"
            } `
            -Body $payload
        
        $fullResponse = $response.choices[0].message.content
        
        # Debug - Show the raw response:
        Write-Host "Raw Response:\n"$fullResponse
        
        # Clean the response first
        $fullResponse = Clean-AIResponse -Response $fullResponse
        
        # Parse the response to extract description and traits
        # The response should have description, then 3 line breaks, then the trait list
        if ($fullResponse -match '^(.+?)(?:\r\n|\n){3}(.+)$') {
            $characterDescription = $matches[1].Trim()
            $characterTraits = $matches[2].Trim()
        } else {
            # Fallback: split by multiple newlines
            $parts = $fullResponse -split "(?:\r\n|\n){3,}"
            if ($parts.Count -ge 2) {
                $characterDescription = $parts[0].Trim()
                $characterTraits = $parts[1].Trim()
            } else {
                # Last fallback: use first line as description, rest as traits
                $lines = $fullResponse -split "`n"
                if ($lines.Count -ge 1) {
                    $characterDescription = $lines[0].Trim()
                    if ($lines.Count -ge 2) {
                        # Only join non-empty lines with commas
                        $nonEmptyLines = $lines[1..($lines.Count-1)] | Where-Object { $_.Trim() -ne "" }
                        $characterTraits = ($nonEmptyLines -join ", ").Trim()
                    }
                }
            }
        }
        
        # Clean up description (remove extra whitespace)
        $characterDescription = $characterDescription -replace '\s+', ' '
        
        # Save to wordbank.txt
        @"
$TriggerWord
$characterDescription
$characterTraits
"@ | Set-Content -Path $wordbankFile -NoNewline
        
        Write-Host ""
        Write-Host "Character wordbank saved to: wordbank.txt"
        Write-Host "Description: $characterDescription"
        Write-Host "Traits: $characterTraits"
        Write-Host ""
        
        return $true
    }
    catch {
        Write-Host "Error generating wordbank: $_"
        return $false
    }
}

# Check for images in current directory
$images = Get-ChildItem -Path . -File | Where-Object { $_.Extension -match '\.(png|jpg|jpeg|webp)$' }

if ($images.Count -eq 0) {
    Write-Host "No images found in current directory: $PWD"
    Write-Host ""
    
    # Look for subdirectories
    $directories = Get-ChildItem -Directory
    
    if ($directories.Count -eq 0) {
        Write-Host "ERROR: No images or subdirectories found in current directory."
        Write-Host "Please run the script from a directory containing images or image folders."
        exit 1
    }
    
    # Display menu of directories
    Write-Host "Found $($directories.Count) subdirectories:"
    Write-Host ""
    for ($i = 0; $i -lt $directories.Count; $i++) {
        Write-Host "[$($i + 1)] $($directories[$i].Name)"
    }
    Write-Host ""
    
    # Prompt user to select a directory
    do {
        $selection = Read-Host "Select a directory (1-$($directories.Count))"
        $validSelection = $false
        
        if ($selection -match '^\d+$') {
            $num = [int]$selection
            if ($num -ge 1 -and $num -le $directories.Count) {
                $validSelection = $true
                $selectedDir = $directories[$num - 1]
                Set-Location $selectedDir.FullName
                Write-Host ""
                Write-Host "Changed to directory: $selectedDir"
                Write-Host ""
                
                # Update wordbankFile to new directory
                $wordbankFile = Join-Path $PWD "wordbank.txt"
                
                # Re-check for images in the new directory
                $images = Get-ChildItem -Path . -File | Where-Object { $_.Extension -match '\.(png|jpg|jpeg|webp)$' }
                
                if ($images.Count -eq 0) {
                    Write-Host "WARNING: No images found in selected directory."
                    exit 1
                }
            }
        }
    } while (-not $validSelection)
} else {
    # Images found in current directory, set wordbankFile path
    $wordbankFile = Join-Path $PWD "wordbank.txt"
}

# Prompt for trigger word (optional)
Write-Host "Enter a trigger word to prepend to all descriptions (optional, press Enter to skip):"
$triggerWord = Read-Host "Trigger word"

if ($triggerWord -ne "") {
    Write-Host "Trigger word set: $triggerWord"
    Write-Host ""
    
    # Ask if trigger word should be prepended to captions
    Write-Host "Do you want to prepend the trigger word to the beginning of each caption? (Y/N, default: Y)"
    $prependInput = Read-Host "Prepend trigger word"
    if ($prependInput -ne 'N' -and $prependInput -ne 'n') {
        $prependTriggerWord = $true
        Write-Host "Trigger word will be prepended to captions."
    } else {
        $prependTriggerWord = $false
        Write-Host "Trigger word will NOT be prepended to captions (will be used in prompts only)."
    }
    Write-Host ""
} else {
    Write-Host "No trigger word set."
    Write-Host ""
}

# Check for existing wordbank.txt
if (Test-Path $wordbankFile) {
    Write-Host "Existing wordbank.txt file found."
    Write-Host "Loading character description and traits from existing file..."
    Write-Host ""
    
    # Read wordbank.txt
    $wordbankLines = Get-Content $wordbankFile
    if ($wordbankLines.Count -ge 3) {
        # Line 1: Trigger word (may differ from input, use the one from wordbank)
        $triggerWord = $wordbankLines[0].Trim()
        # Line 2: Character description
        $characterDescription = $wordbankLines[1].Trim()
        # Line 3: Character traits
        $characterTraits = $wordbankLines[2].Trim()
        
        Write-Host "Using wordbank for trigger word: $triggerWord"
        Write-Host "Description: $characterDescription"
        Write-Host ""
    } else {
        Write-Host "WARNING: wordbank.txt format is invalid. Regenerating..."
        $success = Generate-CharacterWordbank -TriggerWord $triggerWord
        if (-not $success) {
            Write-Host "Failed to generate wordbank. Continuing without it."
            $characterTraits = ""
        }
    }
} else {
    # Generate new wordbank
    if ($triggerWord -ne "") {
        $success = Generate-CharacterWordbank -TriggerWord $triggerWord
        if ($success) {
            # Reload from file to ensure consistency
            $wordbankLines = Get-Content $wordbankFile
            if ($wordbankLines.Count -ge 3) {
                $triggerWord = $wordbankLines[0].Trim()
                $characterDescription = $wordbankLines[1].Trim()
                $characterTraits = $wordbankLines[2].Trim()
            }
        }
    }
}

# Prompt for individual caption files (optional)
Write-Host "Do you want to create individual caption files for each image? (Y/N, default: N)"
$createIndividualFilesInput = Read-Host "Create individual caption files"
$createIndividualFiles = $createIndividualFilesInput -eq 'Y' -or $createIndividualFilesInput -eq 'y'

if ($createIndividualFiles) {
    Write-Host "Individual caption files will be created."
    Write-Host ""
} else {
    Write-Host "Individual caption files will NOT be created."
    Write-Host ""
}

# Handle existing captions.txt file
$captionsFile = Join-Path $PWD "captions.txt"
if (Test-Path $captionsFile) {
    Write-Host "Existing captions.txt file found."
    Write-Host ""
    Write-Host "Please choose an option:"
    Write-Host "  1) Overwrite the existing file"
    Write-Host "  2) Add to existing file (skip already captioned images)"
    Write-Host "  3) Cancel operation"
    Write-Host ""
    
    do {
        $choice = Read-Host "Enter your choice (1/2/3)"
        $validChoice = $false
        
        switch ($choice) {
            '1' {
                $captionsFileMode = 'overwrite'
                $validChoice = $true
                Clear-Content $captionsFile
                Write-Host "Existing captions.txt will be overwritten."
                Write-Host ""
            }
            '2' {
                $captionsFileMode = 'append'
                $validChoice = $true
                Write-Host "Adding to existing captions.txt. Already captioned images will be skipped."
                Write-Host ""
                
                # Read existing captions to track which images are already done
                $existingCaptions = Get-Content $captionsFile
                foreach ($line in $existingCaptions) {
                    if ($line -match '^(.+) ==== .+$') {
                        $capturedImages[$matches[1]] = $true
                    }
                }
                Write-Host "Found $($capturedImages.Count) already captioned image(s)."
                Write-Host ""
            }
            '3' {
                Write-Host "Operation cancelled by user."
                exit 0
            }
        }
    } while (-not $validChoice)
} else {
    New-Item -ItemType File -Path $captionsFile -Force | Out-Null
}

# Filter images based on captions file mode
if ($captionsFileMode -eq 'append') {
    $imagesToProcess = $images | Where-Object { -not $capturedImages.ContainsKey($_.Name) }
    $skippedCount = $images.Count - $imagesToProcess.Count
    if ($skippedCount -gt 0) {
        Write-Host "Skipping $skippedCount already captioned image(s)."
    }
} else {
    $imagesToProcess = $images
}

Write-Host "Found $($imagesToProcess.Count) image(s) to process."
Write-Host "Writing captions to: $captionsFile"
Write-Host ""

# Process all images
$imagesToProcess | ForEach-Object {

    Write-Host "Processing $($_.Name)..."

    # Resize to <3.5MB
    $bytes = Resize-ImageToLimit -Path $_.FullName -MaxBytes $maxSize

    # Convert to Base64
    $base64 = [Convert]::ToBase64String($bytes)

    # Build caption prompt with wordbank if available
    if ($characterTraits -ne "") {
        $promptText = "Describe this image of $($triggerWord) accurately but succinctly. If this is just a simple portrait of $($triggerWord) then the caption should just say 'a portrait of $($triggerWord).' If the image is using a landscape aspect ratio use the phrase ""landscape portrait"" instead of just portrait. If there are specific features or elements in the picture with $($triggerWord) then you may mention those. For example: 'a photo of $($triggerWord) with a ponytail.' If the image contains a watermark mention that. For example 'a photo of $($triggerWord) with a watermark in the bottom right corner.' If $($triggerWord)'s face is not in the shot you may state that. For example: 'a photo of $($triggerWord)'s body without face.' Captions should be one short sentence and simple. Do not surround your caption with any ASCII markup or special tags. Try to use words from the following list to craft your caption whenever possible: $($characterTraits)"
    } else {
        # Fallback prompt without wordbank
        $promptText = "Describe this image of $($triggerWord) accurately but succinctly. If this is just a simple portrait of $($triggerWord) then the caption should just say 'a portrait of $($triggerWord).' If the image is using a landscape aspect ratio use the phrase ""landscape portrait"" instead of just portrait. If there are specific features or elements in the picture with $($triggerWord) then you may mention those. For example: 'a photo of $($triggerWord) with a ponytail.' If the image contains a watermark mention that. For example 'a photo of $($triggerWord) with a watermark in the bottom right corner.' If $($triggerWord)'s face is not in the shot you may state that. For example: 'a photo of $($triggerWord)'s body without face.' Captions should be one short sentence and simple. Do not surround your caption with any ASCII markup or special tags."
    }

    # Build JSON payload
    $payload = @{
        model = "glm-4.6v"
        messages = @(
            @{
                role = "user"
                content = @(
                    @{ type = "text"; text = $promptText }
                    @{ type = "image_url"; image_url = @{ url = "data:image/jpeg;base64,$base64" } }
                )
            }
        )
        stream = $false
    } | ConvertTo-Json -Depth 10

    # Send request
    $response = Invoke-RestMethod `
        -Uri "https://nano-gpt.com/api/v1/chat/completions" `
        -Method POST `
        -Headers @{
            "Authorization" = "Bearer $apiKey"
            "Content-Type"  = "application/json"
        } `
        -Body $payload

    # Get description
    $desc = $response.choices[0].message.content
    
    # Clean the AI response to remove any markup tags
    $desc = Clean-AIResponse -Response $desc
    
    # Prepend trigger word if user requested it
    if ($prependTriggerWord -and $triggerWord -ne "") {
        $finalDesc = "$triggerWord, $desc"
    } else {
        $finalDesc = $desc
    }
    
    # Output description to console
    Write-Host "`nResult for $($_.Name):"
    Write-Host $finalDesc
    
    # Write to captions.txt file
    $line = "$($_.Name) ==== $finalDesc"
    Add-Content -Path $captionsFile -Value $line
    
    # Create individual caption file if requested
    if ($createIndividualFiles) {
        $individualCaptionFile = Join-Path $PWD "$($_.BaseName).txt"
        Set-Content -Path $individualCaptionFile -Value $finalDesc
        Write-Host "Created: $($_.BaseName).txt"
    }
    
    Write-Host "----------------------------------------`n"
}

Write-Host "Done! All captions written to: $captionsFile"
