import React from "react";

// Renders "provider:subject" strings as colored provider badges.
export default function IdentityBadges({ identities = [] }) {
  return (
    <>
      {identities.map((id) => {
        const [provider] = id.split(":");
        return (
          <span key={id} className={`badge ${provider}`} title={id}>
            {provider}
          </span>
        );
      })}
    </>
  );
}
