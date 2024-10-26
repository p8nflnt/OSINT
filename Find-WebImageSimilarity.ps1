<#
.SYNOPSIS
    To locate similar photos on a web site
      1. Provide a base image
      2. Generate a perceptive hash
      3. Recursively crawl a specified website
      4. Generate perceptive hashes for all found images
      5. Compare the perceptive hashes

.NOTES
    Name: Find-WebImageSimilarity.ps1
    Author: Payton Flint
    Version: 1.0
    DateCreated: 2024-Oct

.LINK
    Joshua Hendricks - https://www.joshooaj.com/blog/2024/03/24/image-comparison/
    Joshua Hendricks - https://youtu.be/TTRaDlRWnGg?si=1MSGlU7Ey9HruU1q
    https://github.com/p8nflnt/OSINT/blob/main/Find-WebImageSimilarity.ps1
    https://paytonflint.com/osint-find-similar-images-on-the-web/
#>

$targetSite = "<URL>"
$outputCsv = "<FILEPATH>"
$imgCache = "<PATH>"
$baseImage = "<FILEPATH>"

# Ensure the image cache exists
if (-not (Test-Path $imgCache)) {
    New-Item -ItemType Directory -Path $imgCache | Out-Null
}

# Hashtable to track processed URLs and downloaded images
$processedUrls = @{}
$downloadedImages = @{}

# Generate the perceptual hash for the base image
try {
    $baseImageHash = (Get-PerceptHash -Path $baseImage).Hash
} catch {
    Write-Host "Failed to generate perceptual hash for the base image: $baseImage"
    return
}

# Function to normalize and encode URLs properly
Function Normalize-Url {
    param($url)

    # Check if the URL is relative or absolute
    $uri = New-Object System.Uri($url, [System.UriKind]::RelativeOrAbsolute)

    # If the URL is relative, append the base URL
    if (-not $uri.IsAbsoluteUri) {
        $uri = [uri]::new($targetSite, $uri)
    }

    # Decode and re-encode the URL
    $decodedUrl = [System.Uri]::UnescapeDataString($uri.AbsoluteUri)
    $encodedUrl = [uri]::EscapeUriString($decodedUrl)
    
    # Remove any trailing slashes
    return $encodedUrl.TrimEnd('/')
}

# Function to export images to the CSV file with comparison details
Function Export-ToCsv {
    param(
        [string]$imageUrl,
        [string]$parentUrl,
        [string]$status,
        [string]$perceptualHash,
        [int]$comparisonValue
    )

    # Export the image URL, parent URL, perceptual hash, and comparison value to CSV
    $csvObject = [PSCustomObject]@{
        ImageURL       = $imageUrl
        ParentURL      = $parentUrl
        Status         = $status
        PerceptualHash = $perceptualHash
        ComparisonValue = $comparisonValue
    }
    $csvObject | Export-Csv -Path $outputCsv -Append -NoTypeInformation
}

# Recursive function to get links and download images
Function Get-WebLinks {
    param(
        $targetSite,
        $processedUrls,
        $downloadedImages,
        $parentUrl
    )

    # Normalize the target URL to avoid duplicates
    $normalizedTarget = Normalize-Url $targetSite

    # Check if we've already processed this URL
    if ($processedUrls.ContainsKey($normalizedTarget)) {
        Write-Host "Skipping already processed URL: $normalizedTarget"
        return
    }

    # Add URL to processed list
    $processedUrls[$normalizedTarget] = $true
    Write-Host "Processing: $normalizedTarget"

    try {
        # Fetch the page content
        $page = Invoke-WebRequest $normalizedTarget -ErrorAction Stop

        # Remove protocol to match the domain properly
        $domain = $normalizedTarget -replace 'https?://', '' -replace 'http?://', ''

        # Extract links matching the domain
        $links = ($page.Links | Where-Object { $_.href -like "*$domain*" }).href

        # Determine the base URL (remove any .html or .htm if present)
        $baseUrl = $normalizedTarget -replace "/[^/]+\.html?$", ""

        # Download images belonging to the site
        $images = $page.Images | Where-Object { $_.src -notlike "http*://*" }

        # Process each link
        ForEach ($link in $links) {
            $link = Normalize-Url($link)
            if (-not $processedUrls.ContainsKey($link)) {
                Write-Host "Recursively processing link: $link"
                Get-WebLinks -targetSite $link -processedUrls $processedUrls -downloadedImages $downloadedImages -parentUrl $normalizedTarget
            }
        }

        # Process each image
        ForEach ($image in $images) {
            # Check if the image URL is absolute or relative
            if ($image.src -match "^https?://") {
                # If it's already an absolute URL, use it as is
                $imageUrl = $image.src
            } else {
                # If it's a relative URL, combine it correctly with the base URL
                $imageUrl = "$baseUrl/$($image.src.TrimStart('/'))"
            }

            # Check if the image has already been processed
            if (-not $downloadedImages.ContainsKey($imageUrl)) {
                try {
                    # Mark the image as being processed
                    $downloadedImages[$imageUrl] = $true

                    # Get the image file name and set the output path
                    $imageName = [System.IO.Path]::GetFileName($image.src)
                    $outputPath = Join-Path -Path $imgCache -ChildPath $imageName

                    # Download the image to the specified folder
                    Invoke-WebRequest -Uri $imageUrl -OutFile $outputPath
                    Write-Host "Downloaded image: $outputPath"

                    # Generate the perceptual hash for the downloaded image
                    $imageHash = (Get-PerceptHash -Path $outputPath).Hash
                    Write-Host "Generated perceptual hash: $imageHash"

                    # Compare the downloaded image's hash to the base image's hash
                    $comparisonValue = Compare-PerceptHash -ReferenceHash $baseImageHash -DifferenceHash $imageHash
                    Write-Host "Comparison value: $comparisonValue"

                    # Mark the image as processed and export to CSV
                    Export-ToCsv -imageUrl $imageUrl -parentUrl $normalizedTarget -status "Processed" -perceptualHash $imageHash -comparisonValue $comparisonValue

                    # Delete the image after processing
                    Remove-Item -Path $outputPath -Force
                    Write-Host "Deleted image: $outputPath"
                } catch {
                    Write-Host "Failed to download or process image: $imageUrl. Error: $_"
                }
            } else {
                Write-Host "Skipping already processed image: $imageUrl"
            }
        }
    } catch {
        Write-Host "Error accessing $normalizedTarget`: $_"
    }
}

# Initial call to the function
Get-WebLinks -targetSite $targetSite -processedUrls $processedUrls -downloadedImages $downloadedImages
