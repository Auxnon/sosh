const genLorem = ({
  numParagraphs = 1,
  sentencesPerParagraph = 5,
  wordsPerSentence = 10
} = {}) => {
  // Word bank of Lorem Ipsum text
  const words = [
    "lorem", "ipsum", "dolor", "sit", "amet", "consectetur", "adipiscing", "elit",
    "sed", "do", "eiusmod", "tempor", "incididunt", "ut", "labore", "et", "dolore",
    "magna", "aliqua", "enim", "ad", "minim", "veniam", "quis", "nostrud",
    "exercitation", "ullamco", "laboris", "nisi", "aliquip", "ex", "ea", "commodo",
    "consequat", "duis", "aute", "irure", "in", "reprehenderit", "voluptate",
    "velit", "esse", "cillum", "eu", "fugiat", "nulla", "pariatur", "excepteur",
    "sint", "occaecat", "cupidatat", "non", "proident", "sunt", "culpa", "qui",
    "officia", "deserunt", "mollit", "anim", "id", "est", "laborum"
  ];

  // Helper function to get random integer between min and max (inclusive)
  const getRandomInt = (min, max) =>
    Math.floor(Math.random() * (max - min + 1)) + min;

  // Helper function to shuffle array
  const shuffleArray = array => {
    const shuffled = [...array];
    for (let i = shuffled.length - 1; i > 0; i--) {
      const j = Math.floor(Math.random() * (i + 1));
      [shuffled[i], shuffled[j]] = [shuffled[j], shuffled[i]];
    }
    return shuffled;
  };

  // Generate a single sentence
  const generateSentence = () => {
    const numWords = getRandomInt(
      Math.max(3, wordsPerSentence - 2),
      wordsPerSentence + 2
    );

    const sentence = shuffleArray(words)
      .slice(0, numWords)
      .map((word, index) =>
        index === 0 ? word.charAt(0).toUpperCase() + word.slice(1) : word
      )
      .join(' ');

    return sentence + '.';
  };

  // Generate paragraphs
  const paragraphs = Array.from({ length: numParagraphs }, () => {
    const sentences = Array.from(
      { length: sentencesPerParagraph },
      generateSentence
    );
    return sentences.join(' ');
  });

  return paragraphs.join('\n\n');
};

// Preset configurations
const PRESETS = {
  short: { numParagraphs: 1, sentencesPerParagraph: 3, wordsPerSentence: 8 },
  medium: { numParagraphs: 2, sentencesPerParagraph: 5, wordsPerSentence: 10 },
  long: { numParagraphs: 4, sentencesPerParagraph: 6, wordsPerSentence: 12 }
};

export { genLorem, PRESETS };
