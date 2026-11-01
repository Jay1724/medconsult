# UI rules

- **Mobile: no 50/50 splits.** Under 600px, every two-column grid becomes one column (`assets/mobile.css`). To keep a split on a phone, add the class `keep-split` to that element. New two-column grids must be added to the selector list in `mobile.css`, or use inline `grid-template-columns:1fr 1fr`, which is matched automatically.
