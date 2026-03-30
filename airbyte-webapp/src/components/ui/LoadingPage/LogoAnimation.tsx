import React from "react";
import HabileLabsLogo from "components/ui/illustrations/airbyte-logo-icon.svg?react";

type LogoAnimationProps = {
  title?: string;
  titleId?: string;
  className?: string;
};

export const LogoAnimation: React.FC<LogoAnimationProps> = () => {
  return (
    <div
      style={{
        display: "flex",
        alignItems: "center",
        justifyContent: "center",
        animation: "habilePulse 1.5s ease-in-out infinite",
      }}
    >
      <style>
        {`@keyframes habilePulse {
          0%, 100% { opacity: 1; transform: scale(1); }
          50% { opacity: 0.5; transform: scale(0.92); }
        }`}
      </style>
      <HabileLabsLogo width={60} height={60} />
    </div>
  );
};