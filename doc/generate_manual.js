const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

const DOC_DIR = __dirname;
const README_PATH = path.join(DOC_DIR, 'README.md');
const COMPILED_MD_PATH = path.join(DOC_DIR, 'USER_MANUAL_COMPILED.md');
const OUTPUT_PDF_PATH = path.join(DOC_DIR, '..', 'assets', 'starter', 'USER_MANUAL.pdf');
const CSS_PATH = path.join(DOC_DIR, 'manual-mobile.css');

/**
 * Parses README.md to extract ordered list of markdown files that make up the manual.
 */
function getDocumentOrder() {
    const readmeContent = fs.readFileSync(README_PATH, 'utf-8');
    const links = [];

    // Match standard markdown links: [text](path.md)
    const linkRegex = /\[.*?\]\((.*\.md)\)/g;
    let match;

    // Always include README as the first file
    links.push({
        filepath: 'README.md',
        anchorId: idFromPath('README.md')
    });

    while ((match = linkRegex.exec(readmeContent)) !== null) {
        const relativePath = match[1];
        // Ensure it's not an external URL
        if (!relativePath.startsWith('http')) {
            links.push({
                filepath: relativePath,
                anchorId: idFromPath(relativePath)
            });
        }
    }

    // Remove duplicates (e.g., if README was linked inside README)
    const uniqueLinks = [];
    const seen = new Set();
    for (const link of links) {
        if (!seen.has(link.filepath)) {
            seen.add(link.filepath);
            uniqueLinks.push(link);
        }
    }

    return uniqueLinks;
}

/**
 * Converts a file path like "guides/ai/onboarding.md" to a valid HTML ID "guides-ai-onboarding-md"
 */
function idFromPath(filepath) {
    return filepath.replace(/[\/\.]/g, '-').toLowerCase();
}

/**
 * Processes a single markdown file:
 * 1. Resolves relative image paths so they point correctly from DOC_DIR.
 * 2. Rewrites internal markdown links to point to anchor tags.
 */
function processMarkdownFile(fileInfo, allFiles) {
    const fullPath = path.join(DOC_DIR, fileInfo.filepath);

    if (!fs.existsSync(fullPath)) {
        console.warn(`Warning: File not found: ${fullPath}`);
        return '';
    }

    let content = fs.readFileSync(fullPath, 'utf-8');
    const fileDir = path.dirname(fileInfo.filepath);

    // 1. Inject an invisible anchor at the top of the file content
    content = `<a id="${fileInfo.anchorId}"></a>\n\n` + content;

    // 2. Rewrite internal links
    // Match [text](link)
    // We need to handle links that might be relative to the current file's directory
    const mdLinkRegex = /\[([^\]]+)\]\(([^)]+)\)/g;
    content = content.replace(mdLinkRegex, (match, text, linkUrl) => {
        // Skip external links or anchor links
        if (linkUrl.startsWith('http') || linkUrl.startsWith('#') || linkUrl.startsWith('mailto:')) {
            return match;
        }

        // This is a relative link. We need to resolve what file it points to relative to the doc root.
        const targetRelativePath = path.posix.join(fileDir, linkUrl);

        // Check if this target is one of our compilation files
        const targetFileInfo = allFiles.find(f => f.filepath === targetRelativePath);

        if (targetFileInfo) {
            // Rewrite it as an anchor link
            return `[${text}](#${targetFileInfo.anchorId})`;
        } else if (linkUrl.endsWith('.md')) {
            // It links to an MD file we are NOT concatenating. Hmm.
            // Best effort: convert to anchor anyway assuming it might be added, or leave it.
            return `[${text}](#${idFromPath(targetRelativePath)})`;
        } else if (linkUrl.match(/\.(png|jpg|jpeg|gif|svg)$/i)) {
            // It's an image. We need to fix the path so it works from the DOC_DIR where compiling happens.
            // E.g. inside guides/ai/doc.md: `media/img.png` -> `guides/ai/media/img.png`
            const newImgPath = targetRelativePath;
            return `[${text}](${newImgPath})`;
        }

        return match;
    });

    // Also handle HTML image tags like <img src="...">
    const imgTagRegex = /<img\s+[^>]*src="([^"]+)"[^>]*>/g;
    content = content.replace(imgTagRegex, (match, srcUrl) => {
        if (srcUrl.startsWith('http') || srcUrl.startsWith('data:')) {
            return match;
        }
        const newImgPath = path.posix.join(fileDir, srcUrl);
        return match.replace(`src="${srcUrl}"`, `src="${newImgPath}"`);
    });

    return content;
}

async function main() {
    console.log('1. Analyzing documentation structure from README.md...');
    const documents = getDocumentOrder();
    console.log(`Found ${documents.length} markdown files to compile.`);

    console.log('\n2. Processing and concatenating markdown files...');
    let combinedContent = '';

    // Build TOC
    let tocContent = '# Table of Contents\n\n';

    // First pass: extract titles and process files
    const processedFiles = [];
    for (const doc of documents) {
        console.log(`   Processing: ${doc.filepath}`);
        const content = processMarkdownFile(doc, documents);
        if (content) {
            // Find the first H1 for the TOC
            const h1Match = content.match(/^#\s+(.*)$/m);
            const title = h1Match ? h1Match[1] : doc.filepath;

            // Only add to TOC if it's not the README itself (to avoid redundancy)
            if (doc.filepath !== 'README.md') {
                tocContent += `- [${title}](#${doc.anchorId})\n`;
            }
            processedFiles.push(content);
        }
    }

    // Add title page and TOC
    combinedContent += `---\ntitle: Note Synapse User Manual\n---\n\n`;
    combinedContent += tocContent + '\n\n---\n\n';

    // Add all processed files
    combinedContent += processedFiles.join('\n\n---\n\n');

    console.log(`\n3. Writing compiled markdown to temporary file: ${COMPILED_MD_PATH}`);
    fs.writeFileSync(COMPILED_MD_PATH, combinedContent);

    console.log('\n4. Generating PDF using md-to-pdf...');
    try {
        // Run md-to-pdf. Requires npx.
        const pdfOptions = JSON.stringify({
            width: "90mm",
            height: "180mm",
            margin: { top: "4mm", bottom: "4mm", left: "4mm", right: "4mm" }
        });
        const command = `npx -y md-to-pdf "${COMPILED_MD_PATH}" --stylesheet "${CSS_PATH}" --pdf-options '${pdfOptions}'`;
        console.log(`   Running: ${command}`);
        execSync(command, { stdio: 'inherit', cwd: DOC_DIR });

        const tempPdfPath = COMPILED_MD_PATH.replace('.md', '.pdf');

        console.log(`\n5. Moving generated PDF to ${OUTPUT_PDF_PATH}`);

        // Ensure destination directory exists
        const destDir = path.dirname(OUTPUT_PDF_PATH);
        if (!fs.existsSync(destDir)) {
            fs.mkdirSync(destDir, { recursive: true });
        }

        fs.renameSync(tempPdfPath, OUTPUT_PDF_PATH);

        console.log('\n6. Cleaning up temporary files...');
        fs.unlinkSync(COMPILED_MD_PATH);

        console.log('\n✅ Manual generation complete!');
    } catch (error) {
        console.error('\n❌ Failed to generate PDF.');
        console.error(error.message);
        process.exit(1);
    }
}

main();
