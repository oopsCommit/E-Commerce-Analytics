"""
02_sentiment_nlp.py
Phase 3: Sentiment analysis on review_comment_message — this is genuinely a
Python-only task; SQL can filter/aggregate the text but can't classify it.

IMPORTANT: reviews are in Brazilian Portuguese (pt-BR). Most NLP tutorials
default to English sentiment tools/lexicons, which will silently produce
garbage on this dataset if used as-is. Two approaches are given below —
pick ONE:

  APPROACH A (recommended, more accurate): a multilingual transformer model
  that explicitly supports Portuguese. Heavier (needs torch + a model
  download, ~700MB) but meaningfully more accurate than a lexicon.

  APPROACH B (lighter, faster, less accurate): a Portuguese sentiment
  lexicon via a VADER-style rule-based scorer. No model download, runs
  instantly, but lexicon-based scoring misses negation/sarcasm/context
  much more than a transformer does.

Run: python 02_sentiment_nlp.py --approach transformer
     python 02_sentiment_nlp.py --approach lexicon
"""
import argparse
import pandas as pd
from db_connection import get_engine

engine = get_engine()


def load_reviews() -> pd.DataFrame:
    query = """
        SELECT order_id, review_score, review_comment_message
        FROM olist_clean.dim_reviews
        WHERE review_comment_message IS NOT NULL
          AND CHAR_LENGTH(TRIM(review_comment_message)) > 0
    """
    df = pd.read_sql(query, engine)
    print(f"Loaded {len(df)} reviews with non-empty comment text "
          f"(out of the full dim_reviews table — most Olist reviews have no comment).")
    return df


# =============================================================================
# APPROACH A: multilingual transformer
# Model: nlptown/bert-base-multilingual-uncased-sentiment
#   - trained on multilingual product reviews (English, Dutch, German,
#     French, Italian, Spanish) — Portuguese is not officially in its
#     training list, but as a multilingual BERT it generalizes reasonably
#     well to pt-BR in practice. For production-grade accuracy, swap in a
#     PT-specific model, e.g. "citizenlab/twitter-xlm-roberta-base-sentiment-finetunned"
#     or fine-tune neuralmind/bert-base-portuguese-cased on labeled data.
#   - outputs 1-5 "stars" (analogous to review_score), which is convenient
#     here since we can directly compare it against the real review_score.
# =============================================================================
def run_transformer_sentiment(df: pd.DataFrame) -> pd.DataFrame:
    from transformers import pipeline

    print("Loading transformer model (first run downloads ~700MB)...")
    classifier = pipeline(
        "sentiment-analysis",
        model="nlptown/bert-base-multilingual-uncased-sentiment",
        truncation=True,
        max_length=512,
    )

    # batch in chunks to avoid memory blowup on ~40k+ comments
    batch_size = 32
    predicted_stars = []
    confidences = []
    texts = df["review_comment_message"].tolist()

    for i in range(0, len(texts), batch_size):
        batch = texts[i:i + batch_size]
        outputs = classifier(batch)
        for out in outputs:
            # label looks like "4 stars" -> extract the leading digit
            predicted_stars.append(int(out["label"][0]))
            confidences.append(round(float(out["score"]), 4))
        if i % (batch_size * 20) == 0:
            print(f"  processed {i}/{len(texts)}")

    df = df.copy()
    df["predicted_sentiment_stars"] = predicted_stars
    df["sentiment_confidence"] = confidences
    df["sentiment_method"] = "transformer_nlptown_multilingual"
    return df


# =============================================================================
# APPROACH B: Portuguese lexicon (VADER-style)
# Uses a small hand-rolled positive/negative pt-BR word list as a
# transparent fallback when installing transformers/torch isn't practical
# (e.g. limited disk/CPU). For a real portfolio submission, prefer a
# maintained PT lexicon such as LeIA (https://github.com/rafjaa/LeIA) —
# swap the WORD LISTS below for LeIA's lexicon file for better coverage.
# =============================================================================
POSITIVE_WORDS_PT = {
    "bom", "boa", "otimo", "ótimo", "excelente", "adorei", "recomendo",
    "perfeito", "rapido", "rápido", "gostei", "satisfeito", "qualidade",
    "maravilhoso", "top", "eficiente", "confiavel", "confiável",
}
NEGATIVE_WORDS_PT = {
    "ruim", "pessimo", "péssimo", "horrivel", "horrível", "atraso",
    "atrasado", "demora", "demorou", "problema", "defeito", "quebrado",
    "nao", "não", "cancelado", "errado", "decepcionado", "insatisfeito",
    "nunca", "veio", "faltando",
}


def run_lexicon_sentiment(df: pd.DataFrame) -> pd.DataFrame:
    import re

    def score_text(text: str) -> tuple[str, float]:
        words = re.findall(r"\w+", text.lower())
        pos = sum(1 for w in words if w in POSITIVE_WORDS_PT)
        neg = sum(1 for w in words if w in NEGATIVE_WORDS_PT)
        total = pos + neg
        if total == 0:
            return "neutral", 0.0
        polarity = (pos - neg) / total
        label = "positive" if polarity > 0.15 else "negative" if polarity < -0.15 else "neutral"
        return label, round(polarity, 3)

    results = df["review_comment_message"].apply(score_text)
    df = df.copy()
    df["predicted_sentiment_label"] = [r[0] for r in results]
    df["sentiment_polarity"] = [r[1] for r in results]
    df["sentiment_method"] = "lexicon_pt_basic"
    return df


def compare_against_actual_score(df: pd.DataFrame, approach: str):
    """
    Sanity check: does predicted sentiment roughly track the star rating
    the customer actually gave? Large disagreement is worth spot-checking
    manually before trusting the sentiment output further.
    """
    if approach == "transformer":
        df["agrees_within_1_star"] = (df["predicted_sentiment_stars"] - df["review_score"]).abs() <= 1
        agreement_rate = df["agrees_within_1_star"].mean()
        print(f"\nPredicted sentiment agrees with actual review_score within "
              f"±1 star for {agreement_rate:.1%} of reviews.")
    else:
        # map lexicon label to a rough expected score band and compare direction only
        def matches_direction(row):
            if row["predicted_sentiment_label"] == "positive":
                return row["review_score"] >= 4
            if row["predicted_sentiment_label"] == "negative":
                return row["review_score"] <= 2
            return True  # neutral: no strong claim either way
        df["agrees_with_direction"] = df.apply(matches_direction, axis=1)
        print(f"\nPredicted sentiment direction agrees with actual review_score "
              f"for {df['agrees_with_direction'].mean():.1%} of reviews.")


def top_complaint_keywords(df: pd.DataFrame, label_col: str, negative_value, top_n: int = 25):
    """
    Simple, transparent keyword extraction on negative reviews — word
    frequency after removing Portuguese stopwords, not a full topic model.
    Good enough to answer "what are people actually complaining about" at
    a glance; swap in TF-IDF or LDA (sklearn) for a more rigorous version
    if the portfolio write-up wants to go deeper.
    """
    import re
    from collections import Counter

    STOPWORDS_PT = {
        "o", "a", "os", "as", "de", "do", "da", "dos", "das", "em", "no", "na",
        "nos", "nas", "um", "uma", "uns", "umas", "para", "com", "por", "que",
        "e", "é", "foi", "ser", "está", "esta", "este", "isso", "mas", "muito",
        "nao", "não", "produto", "comprei", "recebi", "veio", "pedido", "ja", "já",
        "ate", "até", "mais", "so", "só", "me", "eu", "minha", "meu", "tudo",
        "porem", "porém", "entao", "então", "pois",
    }

    negative_mask = df[label_col] == negative_value
    texts = df.loc[negative_mask, "review_comment_message"].tolist()
    words = []
    for t in texts:
        words.extend(w for w in re.findall(r"\w+", t.lower()) if w not in STOPWORDS_PT and len(w) > 2)

    counts = Counter(words).most_common(top_n)
    print(f"\nTop {top_n} words in negative reviews (n={len(texts)} reviews):")
    for word, n in counts:
        print(f"  {word:<20} {n}")
    return pd.DataFrame(counts, columns=["word", "count"])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--approach", choices=["transformer", "lexicon"], default="lexicon",
                         help="transformer = more accurate, needs torch+model download. "
                              "lexicon = instant, less accurate, no dependencies beyond stdlib.")
    args = parser.parse_args()

    df = load_reviews()

    if args.approach == "transformer":
        df = run_transformer_sentiment(df)
    else:
        df = run_lexicon_sentiment(df)

    compare_against_actual_score(df, args.approach)

    label_col = "predicted_sentiment_stars" if args.approach == "transformer" else "predicted_sentiment_label"
    negative_value = 1 if args.approach == "transformer" else "negative"
    keywords_df = top_complaint_keywords(df, label_col, negative_value)
    keywords_df.to_sql("py_negative_review_keywords", engine, schema="olist_clean",
                         if_exists="replace", index=False)

    out_cols = ["order_id", "review_score"] + [c for c in df.columns if c not in ("order_id", "review_score", "review_comment_message")]
    df[out_cols].to_sql("py_review_sentiment", engine, schema="olist_clean",
                          if_exists="replace", index=False)
    print(f"\nWrote {len(df)} rows to olist_clean.py_review_sentiment")
    print("Wrote top complaint keywords to olist_clean.py_negative_review_keywords")
    print("Both tables can now be joined to fact_order_items/dim_reviews in Power BI.")


if __name__ == "__main__":
    main()
