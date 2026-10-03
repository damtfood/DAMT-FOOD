module.exports = (req, res) => {
  res.status(200).json({ ok: true, service: "DAMT Food API", time: new Date().toISOString() });
};
