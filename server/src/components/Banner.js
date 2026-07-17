import React from "react";

export default function Banner({ kind = "info", children, onClose }) {
  if (!children) return null;
  return (
    <div className={`banner ${kind}`}>
      <span>{children}</span>
      {onClose && (
        <button style={{ float: "right", padding: "0 0.5rem" }} onClick={onClose}>×</button>
      )}
    </div>
  );
}
