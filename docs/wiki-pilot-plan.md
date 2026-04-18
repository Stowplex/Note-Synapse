# Wiki Pilot Plan

## Purpose

Validate the namespace-aware wiki workflow end-to-end on a small corpus.

## Domain and Namespace

- Domain: Machine Learning Fundamentals
- Namespace: `ml`
- All tags: `wiki-source-ml`, `wiki-compiled-ml`, `wiki-index-ml`, etc.

## Source Notes (5)

5 notes, each 300-800 words, tagged `wiki-source-ml`:

1. **"Attention Is All You Need" Summary** — Transformer, self-attention, multi-head
2. **"Word2Vec and Embeddings"** — Word embeddings, skip-gram, CBOW
3. **"Backpropagation Explained"** — Chain rule, gradients, loss functions
4. **"Convolutional Neural Networks"** — Convolutions, pooling, architectures
5. **"Gradient Descent Variants"** — SGD, Adam, learning rates, momentum

## Execution

### Phase 1: Bootstrap
1. Run Wiki Bootstrap → namespace `ml`
2. Verify: `wiki-index-ml` and `wiki-log-ml` notes created
3. Verify: tag-to-workflow binding registered

### Phase 2: Ingest (5 rounds)
For each source (1-5):
1. Tag note `wiki-source-ml` → ingest triggers via tag binding
2. Verify after each:
   - Source unchanged
   - Compiled notes created/updated with `wiki-compiled-ml` + type tags
   - Index and log updated (namespace-scoped)
   - Relationships created
   - No flat tags (no `wiki-source`, `wiki-compiled` without namespace)

### Phase 3: Query (5 queries)
With Wiki Query skill enabled:
1. "How does attention work in transformers?"
2. "Compare word2vec with transformer embeddings"
3. "What role does backpropagation play in training CNNs?"
4. "Differences between SGD and Adam?"
5. "How do convolutions relate to attention mechanisms?"

### Phase 4: Filing (2 syntheses)
File 2 answers as notes tagged `wiki-compiled-ml` + `wiki-synthesis-ml`.

### Phase 5: Lint
1. Introduce issues: remove `## Sources` from one note, create orphan
2. Run Wiki Lint scoped to namespace `ml`
3. Verify: report identifies issues, only in namespace `ml`

## Evaluation Checklist

- [ ] Compiled notes more useful after 5th source than 1st
- [ ] Query quality improves with compiled context
- [ ] All 5 source notes unchanged
- [ ] Add to Note surfaces sufficient for filing
- [ ] Lint identifies real issues within namespace
- [ ] ALL tags carry namespace suffix (no flat tags)
- [ ] Tag-to-workflow binding triggers ingest automatically
- [ ] Multiple namespaces could coexist (no global collision)
- [ ] On cloud model: full ingest per source in one session
